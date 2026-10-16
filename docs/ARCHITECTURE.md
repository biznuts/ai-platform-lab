# Architecture

Two physical machines on a home LAN, both running Ubuntu Server 26.04.1 LTS, form one K3s cluster.

```mermaid
flowchart LR
  user["Client on lab-cp<br/>demo/ask.py or demo/web.py<br/>(dept key)"] -- "port-forward :4000" --> litellm

  subgraph lab-cp ["lab-cp · 16 cores · 61 GB RAM · no GPU"]
    subgraph platform ["ns: platform"]
      litellm["LiteLLM gateway<br/>keys · teams · budgets<br/>model + MCP access"]
      pg[("Postgres<br/>keys, spend logs")]
    end
    subgraph mcp ["ns: mcp"]
      mcpa["kb-finance<br/>search_kb (read-only)"]
      mcpb["kb-hr<br/>search_kb (read-only)"]
    end
    subgraph data ["ns: data"]
      qdrant[("Qdrant<br/>kb_finance · kb_hr")]
      tei["Embeddings<br/>bge-small (CPU)"]
    end
  end

  subgraph lab-gpu ["lab-gpu · RTX 3070 Ti 8 GB · tainted nvidia.com/gpu"]
    vllm["vLLM<br/>Qwen2.5-3B-Instruct-AWQ<br/>alias: local-private"]
  end

  cohere["Cohere API<br/>alias: cloud-general"]

  litellm --> pg
  litellm -- "confidential + public" --> vllm
  litellm -- "public only" --> cohere
  litellm -- "finance key only" --> mcpa
  litellm -- "hr key only" --> mcpb
  mcpa --> qdrant
  mcpb --> qdrant
  mcpa --> tei
  mcpb --> tei
```

## Request path

1. The demo client opens LiteLLM's `/mcp` endpoint and calls `/v1/chat/completions`, both with the
   department's virtual key.
2. LiteLLM checks the key: which model aliases it may use, which MCP servers it may see, and its
   remaining budget.
3. The model asks for `search_kb`. The client calls the tool through LiteLLM, which forwards the call
   to that department's MCP server with that server's own bearer token.
4. The MCP server embeds the query, searches **its own** collection (fixed by its `DEPT` setting),
   writes an audit line, and returns passages with `source_id`s.
5. The model answers and cites the `source_id`s.

## Controls by layer

| Layer | Control |
|---|---|
| Gateway | Per-team model allow-list (classification rule), MCP server allow-list, budgets, spend logs |
| Network | Default-deny ingress per namespace; only LiteLLM reaches vLLM and MCP; only MCP reaches Qdrant |
| MCP server | One tool, no write path, bounded input, department fixed at start-up, bearer token, audit log |
| Scheduling | GPU node tainted; only vLLM and the NVIDIA device plugin tolerate it, and only vLLM requests `nvidia.com/gpu` |
| Secrets | Local files outside git, then Kubernetes secrets; nothing in images or config |

See `ADR-001-ai-workload-placement.md` for why each workload runs where it does, and `SECURITY.md`
for the threat model.
