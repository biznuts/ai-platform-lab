variable "kubeconfig_path" {
  description = "Path to the K3s kubeconfig (outside the repo). Terraform runs on lab-cp."
  type        = string
  default     = "~/.kube/config"
}

variable "vllm_model" {
  description = "Hugging Face repo id served by vLLM. 3B fits an 8 GB RTX 3070 Ti with room for KV cache."
  type        = string
  default     = "Qwen/Qwen2.5-3B-Instruct-AWQ"
}

# Alternative for a stretch test: "Qwen/Qwen2.5-7B-Instruct-AWQ" (~5.5 GB of weights; very tight on 8 GB).
variable "vllm_model_alt_7b" {
  description = "Documented alternative; set vllm_model to this value to try it."
  type        = string
  default     = "Qwen/Qwen2.5-7B-Instruct-AWQ"
}

variable "vllm_image" {
  type    = string
  default = "vllm/vllm-openai:v0.30.0" # 2026-09-22 release; the default image is CUDA 13, so the node needs a 580+ driver
}

variable "litellm_image" {
  type    = string
  default = "ghcr.io/berriai/litellm:v1.103.3" # patch release of the previous minor (2026-10-03), not the moving main-stable
}

variable "tei_image" {
  type    = string
  default = "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4"
}

variable "embedding_model" {
  type    = string
  default = "BAAI/bge-small-en-v1.5"
}

variable "mcp_image" {
  description = "Built locally from mcp-servers/ and imported into K3s (see README)."
  type        = string
  default     = "kb-mcp:0.1.3"
}

variable "departments" {
  description = "One MCP server per department; must match ALLOWED_DEPTS in mcp-servers/kb_mcp/core.py."
  type        = set(string)
  default     = ["finance", "hr"]
}
