"""Pure logic for the KB server: no network, no MCP imports, so it is unit-tested directly.

Isolation rule: the Qdrant collection is chosen from SERVER CONFIG (the DEPT env var) when the
process starts. Nothing in a tool call can name, widen or change it.
"""
from __future__ import annotations

import hashlib
import json
import sys
import time
from dataclasses import dataclass
from typing import Callable, Sequence

# Must match terraform var.departments and data/<dept>/ folders.
ALLOWED_DEPTS = {"finance": "kb_finance", "hr": "kb_hr"}

TOP_K_MIN, TOP_K_MAX, TOP_K_DEFAULT = 1, 8, 4
MAX_QUERY_CHARS = 500


def collection_for(dept: str) -> str:
    """Map a configured department to its collection; refuse anything not on the allow-list."""
    try:
        return ALLOWED_DEPTS[dept]
    except KeyError:
        raise ValueError(f"unknown department {dept!r}; expected one of {sorted(ALLOWED_DEPTS)}") from None


def clamp_top_k(top_k: object) -> int:
    """Coerce to an int in [TOP_K_MIN, TOP_K_MAX]. Bools and non-numbers fall back to the default."""
    if isinstance(top_k, bool):
        return TOP_K_DEFAULT
    try:
        k = int(top_k)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return TOP_K_DEFAULT
    return max(TOP_K_MIN, min(TOP_K_MAX, k))


def validate_query(query: object) -> str:
    if not isinstance(query, str):
        raise ValueError("query must be a string")
    q = query.strip()
    if not q:
        raise ValueError("query is empty")
    if len(q) > MAX_QUERY_CHARS:
        raise ValueError(f"query longer than {MAX_QUERY_CHARS} characters")
    return q


def query_digest(query: str) -> str:
    """SHA-256 of the query: lets the audit log correlate calls without storing the text."""
    return hashlib.sha256(query.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class Hit:
    source_id: str  # "<file>#<chunk>", used for citations
    score: float
    text: str


Embed = Callable[[str], Sequence[float]]
VectorSearch = Callable[[str, Sequence[float], int], Sequence[Hit]]  # (collection, vector, limit)


def search(query: object, top_k: object, *, collection: str, embed: Embed, vector_search: VectorSearch) -> list[Hit]:
    """Validate input, then search ONLY the collection fixed at start-up."""
    q = validate_query(query)
    k = clamp_top_k(top_k)
    return list(vector_search(collection, embed(q), k))[:k]


def audit_line(*, dept: str, caller: str | None, query: str, top_k: int, hits: Sequence[Hit],
               started: float, status: str, error: str | None = None) -> str:
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": "mcp.tool_call",
        "tool": "search_kb",
        "dept": dept,
        "caller": caller or "unknown",
        "query_sha256": query_digest(query) if isinstance(query, str) else None,
        "top_k": top_k,
        "result_ids": [h.source_id for h in hits],
        "latency_ms": round((time.monotonic() - started) * 1000, 1),
        "status": status,
    }
    if error:
        record["error"] = error
    return json.dumps(record, separators=(",", ":"))


def emit(line: str) -> None:
    print(line, file=sys.stdout, flush=True)
