"""Browser front end for demo/ask.py: pick a department, ask a question, and see the answer, the tool
calls and the sources. It runs the same code as the CLI (ask.steps), so every request still goes through
LiteLLM with that department's key, and LiteLLM decides which models and tools the key may use.

  kubectl -n platform port-forward svc/litellm 4000:4000 &
  .venv/bin/python demo/web.py                      # listens on 127.0.0.1:8090 on lab-cp only
  ssh -L 8090:127.0.0.1:8090 <you>@<lab-cp-ip>      # on your PC, then open http://127.0.0.1:8090

The keys stay in demo/keys.json on lab-cp; the browser only sends a department name. Like the CLI's
--dept, the department picker stands in for a real login (docs/SECURITY.md).
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import re
import sys
import time
import uuid
from pathlib import Path

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response
from starlette.routing import Route

import ask

STATIC = Path(__file__).with_name("web")
DEPTS = ("finance", "hr")
MODELS = ("local-private", "cloud-general")
TOOLS = {f"kb_{d}-search_kb": d for d in DEPTS}  # offered for the direct-call test -> its department
MAX_QUESTION = 500  # the MCP server caps queries at 500 characters too
TIMEOUT = 180       # seconds; the first request after vLLM restarts is slow
# Sources link to the document in the public repo. A source id is "<file>#<chunk>".
REPO_DATA = "https://github.com/biznuts/ai-platform-lab/blob/main/data"
SOURCE_ID = re.compile(r"([A-Za-z0-9_-]+\.md)#\d+")

# Same-origin page, no inline script or style, never framed.
SECURITY_HEADERS = [
    (b"content-security-policy",
     b"default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
    (b"x-content-type-options", b"nosniff"),
    (b"referrer-policy", b"no-referrer"),
    (b"cache-control", b"no-store"),
]

log = logging.getLogger("web")
gpu = asyncio.Semaphore(1)  # one question at a time: the lab has one consumer GPU


def links(sources: list[str], dept: str) -> dict[str, str]:
    """source id -> URL of its document. Ids that do not look like ours get no link."""
    return {s: f"{REPO_DATA}/{dept}/{m[1]}" for s in sources if (m := SOURCE_ID.fullmatch(s))}


def public(e: dict, ref: str, dept: str) -> dict:
    """What the browser may see of an event. Gateway and tool error text goes to the log, not the page.
    `dept` is the department whose knowledge base produced the sources."""
    match e["event"]:
        case "direct" if not e["allowed"]:
            log.info("ref=%s direct call refused: %s", ref, e["text"])
            denied = "not allowed" in e["text"]
            return {"event": "direct", "allowed": False,
                    "text": "This key may not call that tool." if denied else "The tool call failed."}
        case "direct":
            return {"event": "direct", "allowed": True, "sources": e["sources"], "ms": e["ms"],
                    "links": links(e["sources"], dept)}
        case "answer":
            return {**e, "links": links(e["sources"], dept)}
        case "refused":
            log.info("ref=%s gateway refused: HTTP %s %s", ref, e["status"], e["text"])
            text = {403: "This department's key may not use this model.",
                    401: "The gateway rejected the key."}.get(e["status"], "The gateway refused the request.")
            return {"event": "refused", "status": e["status"], "text": text}
    return e


async def api_ask(request: Request) -> Response:
    # Log id: shown with every result and error, and written on each line this request logs, so a
    # generic message on the page can be matched to the detail in this server's log.
    ref = uuid.uuid4().hex[:8]
    # A JSON content type cannot be sent cross-site without a CORS preflight, which this server never allows.
    if request.headers.get("content-type", "").split(";")[0].strip() != "application/json":
        return JSONResponse({"error": "Expected a JSON request.", "ref": ref}, 415)
    try:
        body = await request.json()
    except ValueError:
        body = None
    if not isinstance(body, dict):
        return JSONResponse({"error": "Invalid request.", "ref": ref}, 400)
    dept, model, tool, question = (body.get(k) for k in ("dept", "model", "tool", "question"))
    question = question.strip() if isinstance(question, str) else ""
    if dept not in DEPTS or model not in MODELS or (tool is not None and tool not in TOOLS) \
            or not 0 < len(question) <= MAX_QUESTION:
        return JSONResponse({"error": f"Invalid request. Questions are 1 to {MAX_QUESTION} characters.",
                             "ref": ref}, 400)

    # Like the MCP audit log, never log the question itself.
    log.info("ref=%s dept=%s model=%s tool=%s", ref, dept, model, tool or "-")
    started, events, failure = time.perf_counter(), [], None
    source_dept = TOOLS[tool] if tool else dept
    try:
        async with gpu, asyncio.timeout(TIMEOUT):
            async for e in ask.steps(dept, question, model, tool, caller=f"web-user-{dept}"):
                events.append(public(e, ref, source_dept))
    except* httpx.ConnectError:
        failure = (502, "The gateway is not reachable. Is the port-forward to LiteLLM running?")
    except* TimeoutError:
        failure = (504, "The request took too long.")
    except* Exception:
        log.exception("ref=%s failed", ref)
        failure = (500, "Something went wrong.")
    if failure:
        log.warning("ref=%s status=%s", ref, failure[0])
        return JSONResponse({"error": failure[1], "ref": ref}, failure[0])
    ms = ask.elapsed_ms(started)
    log.info("ref=%s done in %.1f ms: %s", ref, ms, [e["event"] for e in events])
    return JSONResponse({"ref": ref, "ms": ms, "events": events})


def static(name: str, media_type: str):
    async def handler(request: Request) -> Response:
        return FileResponse(STATIC / name, media_type=media_type)
    return handler


app = Starlette(routes=[
    Route("/", static("index.html", "text/html; charset=utf-8")),
    Route("/app.js", static("app.js", "text/javascript; charset=utf-8")),
    Route("/style.css", static("style.css", "text/css; charset=utf-8")),
    Route("/api/ask", api_ask, methods=["POST"]),
])


class Guard:
    """Answer only to this machine's own address (blocks DNS rebinding), refuse cross-site requests, and add
    the security headers to every response."""

    def __init__(self, inner, port: int) -> None:
        self.inner = inner
        self.hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        self.origins = {f"http://{h}" for h in self.hosts}

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            return await self.inner(scope, receive, send)
        headers = {k.decode("latin-1"): v.decode("latin-1") for k, v in scope["headers"]}
        origin = headers.get("origin")
        if headers.get("host") not in self.hosts or (origin is not None and origin not in self.origins):
            return await JSONResponse({"error": "Forbidden."}, 403)(scope, receive, send)

        async def send_with_headers(message) -> None:
            if message["type"] == "http.response.start":
                message["headers"] = list(message.get("headers", [])) + SECURITY_HEADERS
            await send(message)

        await self.inner(scope, receive, send_with_headers)


def main() -> None:
    p = argparse.ArgumentParser(description="Browser front end for demo/ask.py (loopback only).")
    p.add_argument("--port", type=int, default=8090)
    a = p.parse_args()
    if not ask.KEYS.exists():
        sys.exit("demo/keys.json is missing. Create it with litellm/create-teams-and-keys.sh first.")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per gateway call is noise
    log.info("gateway %s; open http://127.0.0.1:%d through an SSH tunnel", ask.BASE, a.port)
    # Loopback only, on purpose: reach it over SSH, never on the LAN.
    uvicorn.run(Guard(app, a.port), host="127.0.0.1", port=a.port)


if __name__ == "__main__":
    main()
