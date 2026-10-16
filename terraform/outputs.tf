output "port_forwards" {
  description = "Run these from the workstation for ingest and the demo."
  value = {
    litellm    = "kubectl -n platform port-forward svc/litellm 4000:4000"
    qdrant     = "kubectl -n data port-forward svc/qdrant 6333:6333"
    embeddings = "kubectl -n data port-forward svc/embeddings 8081:80"
  }
}

output "served_model" {
  value = var.vllm_model
}
