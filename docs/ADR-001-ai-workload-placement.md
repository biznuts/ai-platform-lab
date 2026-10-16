# ADR-001: Where an AI workload runs

- **Status:** Accepted for this lab
- **Date:** 2026-10

## Context

An organization runs AI for many departments. Each workload (a chat assistant, a RAG search, a
batch summarization job) could run on its own GPUs, in Azure, AWS or Google Cloud, or through an
external model API such as Cohere. The departments hold data at different sensitivity levels, and
some of it must stay in Canada. Each choice trades off privacy, performance and cost, and the
decision has to be made the same way every time, not case by case.

## Options

| Option | Strengths | Weaknesses |
|---|---|---|
| **On-prem GPU** (this lab: RTX 3070 Ti on K3s) | Data never leaves the network; no per-token cost; predictable latency on the LAN | Up-front hardware cost; small models only on small GPUs; we run patching, capacity and failures |
| **Azure** (Canada Central / Canada East) | Canadian regions; managed Kubernetes and GPU VMs; fits existing Entra ID | GPU quota and availability; costly if left idle |
| **AWS** (ca-central-1, ca-west-1) | Canadian regions; wide GPU choice; strong managed services | Another identity and billing model to govern |
| **Google Cloud** (northamerica-northeast1/2) | Canadian regions; good managed Kubernetes and accelerators | Same governance cost as AWS; fewer existing skills |
| **External model API** (e.g. Cohere) | No infrastructure; strong models; pay per use | Data goes to a third party; residency depends on the contract; per-token cost grows with use |

## Decision criteria, in order

1. **Data classification and sovereignty.** This criterion is a filter, not a weight. Confidential
   or regulated data runs only on-prem or in a Canadian region under the organization's own
   tenancy and contract. It never goes to an external API unless the contract says in writing that
   the data stays in Canada and is not retained.
2. **Utilization and latency.** Among the options that pass step 1: steady, high-use workloads
   favour owned GPUs; bursty or experimental workloads favour cloud or an API. Interactive use
   needs low latency; batch jobs can wait.
3. **Cost.** Compare the total cost over the planning horizon, not the list price.

### Break-even reasoning (illustrative assumptions, not quotes)

Assume an on-prem inference server costs $12,000, amortized over 36 months (about $333/month),
plus about $100/month for power and operations, so about $433/month. Assume a comparable cloud GPU
VM costs $1.20/hour on demand.

Break-even = 433 / 1.20 ≈ **360 hours/month**, about half the hours in a month.

- A workload busy for more than about half of every month is cheaper on owned hardware.
- A workload busy for a few hours a week is cheaper in the cloud, or through an API if step 1
  allows it.

Replace these numbers with real quotes before using this reasoning for a decision.

## Decision rules

| Classification | Utilization | Runs on |
|---|---|---|
| Confidential / regulated | any | On-prem GPU (`local-private`); or a Canadian-region private deployment if on-prem capacity is short |
| Internal | high, steady | On-prem GPU |
| Internal | low or bursty | Canadian-region cloud |
| Public | any | Cheapest that meets latency, including an external API (`cloud-general`) |

In the lab, only the classification part of these rules is enforced, through LiteLLM access rather
than documentation: the Dept A team (confidential) can use only the `local-private` alias, while
Dept B (public) can also use `cloud-general`. The lab has no internal tier, and utilization and cost
are design guidance that the gateway does not check.

## Consequences

- Every workload needs a data classification before it is placed. No classification means it
  runs on-prem.
- On-prem capacity becomes a shared resource that needs a queue and a capacity plan.
- Gateway access lists become a governance artefact: changing who can use which model is a
  reviewed change.
- Small on-prem GPUs limit model size, so confidential workloads may get a weaker model than
  public ones. Accept this, or fund larger on-prem or Canadian-region capacity.

## When to revisit

- A provider offers contractual Canadian residency with no retention.
- Sustained on-prem GPU utilization stays above about 70% (buy more) or below about 20% (move
  workloads to the cloud).
- Cloud GPU prices or the hardware refresh cycle move the break-even point by more than 25%.
- A new data class or regulation applies, for example health data under PHIPA.
