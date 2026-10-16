# Namespaces and secrets. Secrets are read from terraform/secrets/* (gitignored); see secrets/README.md.
# They still end up in terraform.tfstate, which is also gitignored — keep the state file local.

locals {
  namespaces = ["platform", "models", "mcp", "data"]
  secret     = { for name in ["litellm_master_key", "postgres_password", "cohere_api_key", "mcp_token_dept_a", "mcp_token_dept_b"] : name => trimspace(file("${path.module}/secrets/${name}")) }
}

resource "kubernetes_namespace_v1" "ns" {
  for_each = toset(local.namespaces)
  metadata {
    name = each.key
  }
}

# One bearer token per MCP server: LiteLLM holds both, each MCP server only knows its own.
resource "kubernetes_secret_v1" "mcp_token" {
  for_each = var.departments
  metadata {
    name      = "mcp-token-${each.key}"
    namespace = kubernetes_namespace_v1.ns["mcp"].metadata[0].name
  }
  data = { token = local.secret["mcp_token_${replace(each.key, "-", "_")}"] }
}
