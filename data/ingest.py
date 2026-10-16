"""Chunk data/<dept>/*.md, embed via text-embeddings-inference, upsert into per-department Qdrant
collections. Idempotent: point ids are derived from (file, chunk), so re-running overwrites.

  kubectl -n data port-forward svc/qdrant 6333:6333
  kubectl -n data port-forward svc/embeddings 8081:80
  python data/ingest.py
"""
from __future__ import annotations

import os
import uuid
from pathlib import Path

import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

HERE = Path(__file__).parent
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
EMBED_URL = os.environ.get("EMBED_URL", "http://localhost:8081")
DEPTS = {"finance": "kb_finance", "hr": "kb_hr"}  # same map as mcp-servers/kb_mcp/core.py
MAX_CHARS = 800
NS = uuid.UUID("6f1b8f0e-0000-4000-8000-00000000ab01")  # fixed namespace for deterministic ids


def chunks(text: str) -> list[str]:
    """Split on blank lines, then pack paragraphs up to MAX_CHARS."""
    out, cur = [], ""
    for para in (p.strip() for p in text.split("\n\n")):
        if not para:
            continue
        if cur and len(cur) + len(para) + 2 > MAX_CHARS:
            out.append(cur)
            cur = para
        else:
            cur = f"{cur}\n\n{para}" if cur else para
    if cur:
        out.append(cur)
    return out


def embed(http: httpx.Client, texts: list[str]) -> list[list[float]]:
    r = http.post(f"{EMBED_URL}/embed", json={"inputs": texts, "normalize": True})
    r.raise_for_status()
    return r.json()


def main() -> None:
    qdrant = QdrantClient(url=QDRANT_URL, timeout=30)
    with httpx.Client(timeout=60.0) as http:
        for dept, collection in DEPTS.items():
            records = [(f.name, i, c)
                       for f in sorted((HERE / dept).glob("*.md"))
                       for i, c in enumerate(chunks(f.read_text(encoding="utf-8")))]
            vectors = embed(http, [c for _, _, c in records])
            if not qdrant.collection_exists(collection):
                qdrant.create_collection(collection, vectors_config=VectorParams(size=len(vectors[0]), distance=Distance.COSINE))
            qdrant.upsert(collection, points=[
                PointStruct(id=str(uuid.uuid5(NS, f"{dept}/{src}#{i}")), vector=v,
                            payload={"source": src, "chunk": i, "text": text, "dept": dept})
                for (src, i, text), v in zip(records, vectors)
            ])
            print(f"{collection}: {len(records)} chunks from {dept}/")


if __name__ == "__main__":
    main()
