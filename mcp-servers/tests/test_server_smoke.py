"""Import the real server module and check what it exposes over MCP. No network: the Qdrant and
HTTP clients are created lazily and never called here."""
import asyncio
import importlib
import sys


def load_server(tmp_path, monkeypatch, dept="dept-a"):
    token = tmp_path / "token"
    token.write_text("test-token\n", encoding="utf-8")
    monkeypatch.setenv("DEPT", dept)
    monkeypatch.setenv("MCP_TOKEN_FILE", str(token))
    sys.modules.pop("kb_mcp.server", None)
    return importlib.import_module("kb_mcp.server")


def test_exposes_only_search_kb(tmp_path, monkeypatch):
    server = load_server(tmp_path, monkeypatch)
    tools = asyncio.run(server.mcp.list_tools())
    assert [t.name for t in tools] == ["search_kb"]


def test_tool_inputs_are_query_and_top_k_only(tmp_path, monkeypatch):
    # The injected Context must not leak into the schema; there is no way to pass a collection.
    server = load_server(tmp_path, monkeypatch)
    (tool,) = asyncio.run(server.mcp.list_tools())
    assert set(tool.inputSchema["properties"]) == {"query", "top_k"}
    assert tool.inputSchema.get("required") == ["query"]


def test_collection_comes_from_config(tmp_path, monkeypatch):
    server = load_server(tmp_path, monkeypatch, dept="dept-b")
    assert server.COLLECTION == "kb_dept_b"
