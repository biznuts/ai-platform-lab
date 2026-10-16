# ai-platform-lab

A small, working enterprise-AI platform on two home PCs: an on-prem GPU Kubernetes cluster that
serves an open-weights model behind an AI gateway, with per-department MCP knowledge-base servers,
RAG with citations, and placement rules for where each workload may run.

Terraform provisions the Kubernetes resources (namespaces, deployments, Helm charts, network
policies, secrets). Everything else is a step in the Quickstart: node setup (`bootstrap/`), secret
files, the MCP image build, the gateway's teams and keys, and the knowledge-base ingest. All data is
fictional.

## What it demonstrates

| Area | In this repo |
|---|---|
| Kubernetes + GPU on-prem | Two-node K3s; GPU node labelled and tainted; NVIDIA device plugin; `nvidia` RuntimeClass (`bootstrap/`, `terraform/gpu.tf`) |
| Open-weights model serving | vLLM serving Qwen2.5-3B-Instruct-AWQ on an RTX 3070 Ti (8 GB), with tool calling (`terraform/models.tf`) |
| AI gateway | LiteLLM: virtual keys, teams, budgets, spend logs in Postgres, model and MCP access per team (`litellm/`) |
| MCP servers | One narrow, read-only `search_kb` tool per department; bearer auth; JSON audit log; unit-tested input limits (`mcp-servers/`) |
| RAG | Qdrant + CPU embeddings (bge-small); answers cite `source_id`s (`data/`, `demo/`) |
| Workload placement | Classification → sovereignty → utilization → cost (`docs/ADR-001-ai-workload-placement.md`). The gateway enforces the classification rule: the confidential team cannot use the cloud model |
| Security | Threat model for prompt injection, tool poisoning, cross-tenant leakage and token passthrough (`docs/SECURITY.md`). Scripted checks cover the gateway, network and MCP controls (`demo/verify-controls.sh`), and the demo includes a planted prompt injection (`demo/run-demo.sh`) |

Architecture diagram: `docs/ARCHITECTURE.md`.

## Hardware

| Node | Machine | Role |
|---|---|---|
| `lab-cp` | 16 cores, 61 GB RAM, 2 TB NVMe, no GPU; Ubuntu Server 26.04.1 LTS | K3s server; LiteLLM, Postgres, MCP servers, Qdrant, embeddings. Also runs Terraform and the image build, so the kubeconfig and secrets never leave the lab |
| `lab-gpu` | RTX 3070 Ti 8 GB, 4 cores, 13 GB RAM; Ubuntu Server 26.04.1 LTS | K3s agent, labelled and tainted for GPU work; runs only vLLM and the NVIDIA device plugin |

## Quickstart

Everything below runs **on `lab-cp`**, from a copy of this repo at `~/ai-platform-lab`. You need
SSH access to both nodes and, for the cloud tier only, a personal Cohere trial key.

1. **Bootstrap the nodes**
   ```bash
   # lab-cp: K3s server, then Terraform, buildah, a Python venv and your kubeconfig
   sudo ./bootstrap/install-k3s-server.sh
   sudo ./bootstrap/install-lab-tools.sh
   python3 -m venv .venv && .venv/bin/pip install -r data/requirements.txt -r demo/requirements.txt

   # lab-gpu: driver + container toolkit (reboots once for the driver; run it again afterwards)
   sudo ./bootstrap/gpu-node-prep.sh
   # copy /var/lib/rancher/k3s/server/node-token from lab-cp to lab-gpu over SSH (chmod 600), then:
   sudo ./bootstrap/install-k3s-agent.sh https://<lab-cp-ip>:6443 /root/k3s-node-token
   ```

2. **Build the MCP image and import it into K3s** (no registry, no Docker daemon):
   ```bash
   sudo buildah bud -t kb-mcp:0.1.3 mcp-servers/
   sudo buildah push kb-mcp:0.1.3 docker-archive:/tmp/kb-mcp.tar:kb-mcp:0.1.3
   sudo k3s ctr -n k8s.io images import /tmp/kb-mcp.tar && sudo rm /tmp/kb-mcp.tar
   ```
   Bump the tag (and `mcp_image` in `terraform/variables.tf`) whenever the code changes, so the
   deployment rolls.

3. **Create the secrets and apply**
   ```bash
   # follow terraform/secrets/README.md (generated on lab-cp, mode 600, never printed)
   cd terraform && terraform init && terraform apply && cd ..
   ```
   Without `lab-gpu`, everything except vLLM comes up; vLLM waits in `Pending` and starts once
   the GPU node joins (the first start downloads the model).

4. **Create teams and keys** (writes `demo/keys.json`, mode 600, gitignored):
   ```bash
   kubectl -n platform port-forward svc/litellm 4000:4000 &
   LITELLM_MASTER_KEY="$(cat terraform/secrets/litellm_master_key)" ./litellm/create-teams-and-keys.sh
   ```

5. **Ingest the knowledge bases** (idempotent):
   ```bash
   kubectl -n data port-forward svc/qdrant 6333:6333 &
   kubectl -n data port-forward svc/embeddings 8081:80 &
   .venv/bin/python data/ingest.py
   ```

6. **Verify the controls, then run the demo**
   ```bash
   ./demo/verify-controls.sh                  # 12 checks; needs no GPU and no Cohere key
   PYTHON=.venv/bin/python bash demo/run-demo.sh   # needs vLLM up; step 2 needs the Cohere key
   ```

7. **Optional: ask from a browser** (`demo/web.py`, same code path as `demo/ask.py`):
   ```bash
   .venv/bin/python demo/web.py   # needs the port-forward from step 4; listens on 127.0.0.1:8090 only
   # on your PC: ssh -L 8090:127.0.0.1:8090 <you>@<lab-cp-ip>, then open http://127.0.0.1:8090
   ```
   Pick a department and a model, or run one of the demo scenarios. Each result shows the tools the key
   sees, every tool call, the answer with its citations checked against the retrieved passages, and
   any refusal. The keys stay on `lab-cp`; the browser only sends a department name.

Unit tests (no cluster needed): `cd mcp-servers && pip install -r requirements.txt pytest && python -m pytest`.

### What `verify-controls.sh` checks

| # | Control | Expected |
|---|---|---|
| 1 | Retrieval through the gateway (key → LiteLLM → its MCP server → Qdrant) | answer passages with source ids |
| 2 | Tool visibility per key | each key sees only its own department's tool |
| 3 | Cross-department tool call | refused by LiteLLM; the other department's server never sees the request |
| 4 | Confidential tier asks for the cloud model | HTTP 403 |
| 5 | NetworkPolicy from an unrelated namespace | MCP, Qdrant, embeddings and Postgres blocked; only the gateway reachable |
| 6 | MCP server called without its bearer token | HTTP 401 |
| 7 | Audit log | caller recorded; query stored only as a SHA-256 digest |

All seven passed on 2026-10-07 (before `lab-gpu` joined), on 2026-10-09 with the GPU node in, and on
2026-10-16 after the departments became Finance and HR.

### Demo results with the GPU model (2026-10-16)

| Step | Result |
|---|---|
| 1. Finance asks the local model about its own policy | Correct answer, cited: "within 30 calendar days … `[01-expense-claims.md#0]`", matching the source |
| 2. HR uses the cloud model (Cohere `command-r7b-12-2024`) | Correct answer: "10 paid sick days each calendar year". Cohere often skips inline citations, so the client always prints the source ids the tool returned |
| 3. HR's key calls Finance's tool | Refused by LiteLLM: "User not allowed to call this tool" |
| 3b. Finance asks for the cloud model | Refused: HTTP 403 |
| 4. Planted prompt injection in Finance's data | One tool call, no other tools, system prompt not revealed. The 3B model's summary restates the memo's demands as if they were facts, which is why the boundary is the tool scope, not the model |

Every model-backed step makes exactly one tool call. The system prompt in `demo/ask.py` was picked from
five variants compared at temperature 0: the 3B model needs an explicit "call the tool first", and a
worked citation example made it print raw `<tool_call>` text instead of calling the tool.

vLLM on the RTX 3070 Ti: Qwen2.5-3B AWQ takes 1.95 GiB, leaving a 94,256-token KV cache, enough for
about 23 maximum-length (4,096-token) requests at once. That is vLLM's estimate; the lab has not been
load-tested. Cold start takes about 2.5 minutes once the image and model are cached.
