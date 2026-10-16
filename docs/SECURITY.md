# Security and threat model

Scope: the lab's AI path, from the client through LiteLLM and the MCP servers to Qdrant. The main
assumption is that **the model can be steered by anything it reads**, so the model is never what
enforces a boundary.

| Threat | Example | Mitigation in this lab | Gap / production step |
|---|---|---|---|
| **Prompt injection** | `data/dept-a/07-memo-assistant-update.md` tells the model to call every tool and leak drafts | The model sees one read-only tool scoped to its own department, so there is nothing to escalate to. The system prompt marks retrieved text as data. The client caps tool rounds at 3. | A prompt alone is not a control. In production, add output filtering for confidential markers and human approval for any write tool. |
| **Tool poisoning** | A third-party MCP server hides instructions in a tool description, or changes the tool after approval | Only first-party MCP servers, built from this repo and pinned by image tag. Fixed tool descriptions. | Pin images by digest, sign images, and review tool schemas on change. |
| **Cross-tenant leakage** | Dept B's key reads Dept A's knowledge base | Three layers, each closing a different path: (1) LiteLLM gives each key access to one MCP server only; (2) each MCP server is fixed to one collection by `DEPT`, which no tool input can change; (3) NetworkPolicy allows only MCP pods to reach Qdrant. Demo step 3 proves the refusal. | Below the MCP servers there is only one layer: Qdrant has no API key, and the NetworkPolicy admits any `app=kb-mcp` pod, so a compromised MCP server could read the other department's collection. In production, give each MCP server a Qdrant key scoped to its own collection (Qdrant JWT RBAC). Department-level isolation is also not user-level: production needs permission-aware retrieval, with per-user ACLs stored with each chunk and filtered on the caller's identity from Entra ID. |
| **Token passthrough / confused deputy** | The client's key is forwarded to a backend and used with the backend's broader rights | LiteLLM authenticates the client, then calls each MCP server with that server's own token. The client key never reaches the MCP server or Qdrant. | Follow the MCP authorization spec (OAuth 2.1, audience-bound tokens) when servers need to act as the user. |
| **Unbounded tool input** | Huge `top_k`, very long queries, free-form filters | `top_k` clamped to 1–8, query capped at 500 characters, no filter parameter. Covered by unit tests. | Add rate limits per key (LiteLLM supports RPM/TPM limits). |
| **Data egress to a third party** | Confidential text sent to the cloud model | The Dept A team cannot use `cloud-general`. Demo step 3b proves the refusal. | Restrict egress with NetworkPolicy so only LiteLLM can reach the Internet, and only the Cohere endpoint. |
| **Audit gaps** | No record of who searched what | Each tool call logs a JSON line: department, caller (if forwarded), SHA-256 of the query (not the text), `top_k`, result ids, latency, status. LiteLLM spend logs record key, team and model. Prompt bodies are not logged. | Ship logs to a central SIEM, add retention rules, and alert on refusals. |
| **Secrets exposure** | Keys in git, images or chat | Secrets live in gitignored local files, then Kubernetes secrets. `.example` placeholders only. Separate token per MCP server. | Use a managed secret store (e.g. Azure Key Vault with the CSI driver) and rotate keys. Terraform state holds secrets, so keep it encrypted and remote in production. |

## What this lab does not cover

- TLS inside the cluster (traffic is plain HTTP on the cluster network). Add a service mesh or
  cert-manager in production.
- High availability: one replica of everything, on two home PCs.
- Real identities: department keys stand in for users, and the browser UI's department picker
  (`demo/web.py`) is the same stand-in. Production should map Entra ID groups to LiteLLM teams.
- Real data: everything in `data/` is fictional.
