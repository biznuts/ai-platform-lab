# One knowledge-base MCP server per department. Same image; the department comes from the
# DEPT env var (server config), never from tool input.

resource "kubernetes_deployment_v1" "kb_mcp" {
  for_each = var.departments
  metadata {
    name      = "kb-${each.key}"
    namespace = kubernetes_namespace_v1.ns["mcp"].metadata[0].name
    labels    = { app = "kb-mcp", dept = each.key }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "kb-mcp", dept = each.key }
    }
    template {
      metadata {
        labels = { app = "kb-mcp", dept = each.key }
      }
      spec {
        automount_service_account_token = false # the server needs no Kubernetes API access
        container {
          name              = "kb-mcp"
          image             = var.mcp_image
          image_pull_policy = "IfNotPresent" # image is imported into K3s, not pulled from a registry
          env {
            name  = "DEPT"
            value = each.key
          }
          env {
            name  = "QDRANT_URL"
            value = "http://qdrant.data.svc.cluster.local:6333"
          }
          env {
            name  = "EMBED_URL"
            value = "http://embeddings.data.svc.cluster.local"
          }
          env {
            name  = "MCP_TOKEN_FILE"
            value = "/run/secrets/mcp/token"
          }
          port {
            container_port = 8080
          }
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "token"
            mount_path = "/run/secrets/mcp"
            read_only  = true
          }
          # The root filesystem stays read-only; qdrant-client needs a writable temp dir at import time.
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
        }
        volume {
          name = "token"
          secret {
            secret_name = kubernetes_secret_v1.mcp_token[each.key].metadata[0].name
          }
        }
        volume {
          name = "tmp"
          empty_dir {
            medium     = "Memory"
            size_limit = "16Mi"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "kb_mcp" {
  for_each = var.departments
  metadata {
    name      = "kb-${each.key}"
    namespace = kubernetes_namespace_v1.ns["mcp"].metadata[0].name
  }
  spec {
    selector = { app = "kb-mcp", dept = each.key }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}
