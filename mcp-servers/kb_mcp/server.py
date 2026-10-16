"""FastMCP server over streamable HTTP exposing exactly one read-only tool: search_kb.

Run:  DEPT=finance MCP_TOKEN_FILE=/run/secrets/mcp/token python -m kb_mcp.server
"""
# No `from __future__ import annotations` here: FastMCP inspects the tool's annotations at runtime
# (to find the Context parameter), and string annotations break that.
import hmac
import os
import time
from pathlib import Path

import httpx
import uvicorn
from mcp.server.fastmcp import Context, FastMCP
from qdrant_client import QdrantClient

from . import core

DEPT = os.environ["DEPT"]
COLLECTION = core.collection_for(DEPT)  # fails fast on an unknown department
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
EMBED_URL = os.environ.get("EMBED_URL", "http://localhost:8081")
TOKEN = Path(os.environ["MCP_TOKEN_FILE"]).read_text(encoding="utf-8").strip()
# LiteLLM forwards this header (extra_headers in litellm/config.yaml). The client asserts it, so the
# audit log records it as a claim, not as an authenticated identity.
CALLER_HEADER = os.environ.get("CALLER_HEADER", "x-litellm-end-user-id")

_http = httpx.Client(timeout=15.0)  # TLS verification stays at its default (on)
_qdrant = QdrantClient(url=QDRANT_URL, timeout=15)


def _embed(text: str) -> list[float]:
    # Hugging Face text-embeddings-inference: POST /embed {"inputs": [...]} -> [[...]]
    r = _http.post(f"{EMBED_URL}/embed", json={"inputs": [text], "normalize": True})
    r.raise_for_status()
    return r.json()[0]


def _vector_search(collection: str, vector: list[float], limit: int) -> list[core.Hit]:
    res = _qdrant.query_points(collection_name=collection, query=vector, limit=limit, with_payload=True)
    return [
        core.Hit(source_id=f"{p.payload['source']}#{p.payload['chunk']}", score=float(p.score), text=p.payload["text"])
        for p in res.points
    ]


mcp = FastMCP(f"kb-{DEPT}", stateless_http=True)


@mcp.tool(
    name="search_kb",
    description=(
        f"Search the {DEPT} knowledge base and return short passages with source ids to cite. "
        "Read-only. Returns at most 8 passages."
    ),
)
def search_kb(query: str, ctx: Context, top_k: int = core.TOP_K_DEFAULT) -> list[dict]:
    # FastMCP injects ctx and leaves it out of the tool's input schema.
    started = time.monotonic()
    try:  # the HTTP request behind this tool call (streamable HTTP transport)
        caller = ctx.request_context.request.headers.get(CALLER_HEADER)
    except Exception:
        caller = None
    k = core.clamp_top_k(top_k)
    try:
        hits = core.search(query, k, collection=COLLECTION, embed=_embed, vector_search=_vector_search)
    except ValueError as e:
        core.emit(core.audit_line(dept=DEPT, caller=caller, query=query, top_k=k, hits=[],
                                  started=started, status="rejected", error=str(e)))
        raise
    except Exception:
        core.emit(core.audit_line(dept=DEPT, caller=caller, query=query, top_k=k, hits=[],
                                  started=started, status="error", error="backend failure"))
        raise RuntimeError("search failed")  # generic to the caller; details stay in server logs
    core.emit(core.audit_line(dept=DEPT, caller=caller, query=query, top_k=k, hits=hits,
                              started=started, status="ok"))
    return [{"source_id": h.source_id, "score": round(h.score, 4), "text": h.text} for h in hits]


class BearerAuth:
    """Pure ASGI middleware: every request except /healthz needs the server's own bearer token."""

    def __init__(self, app, token: str):
        self.app, self.expected = app, f"Bearer {token}".encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        if scope.get("path") == "/healthz":
            return await _plain(send, 200, b"ok")
        got = dict(scope.get("headers") or []).get(b"authorization", b"")
        if not hmac.compare_digest(got, self.expected):
            return await _plain(send, 401, b"unauthorized")
        return await self.app(scope, receive, send)


async def _plain(send, status: int, body: bytes) -> None:
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"text/plain"), (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})


def main() -> None:
    app = BearerAuth(mcp.streamable_http_app(), TOKEN)  # MCP endpoint at /mcp
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), log_level="warning")


if __name__ == "__main__":
    main()
