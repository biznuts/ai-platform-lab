# LiteLLM gateway + a small Postgres for virtual keys, teams, budgets and spend logs.

resource "kubernetes_secret_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
  }
  data = {
    LITELLM_MASTER_KEY = local.secret["litellm_master_key"]
    DATABASE_URL       = "postgresql://litellm:${local.secret["postgres_password"]}@postgres.platform.svc.cluster.local:5432/litellm"
    COHERE_API_KEY     = local.secret["cohere_api_key"]
    MCP_TOKEN_DEPT_A   = local.secret["mcp_token_dept_a"]
    MCP_TOKEN_DEPT_B   = local.secret["mcp_token_dept_b"]
  }
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
  }
  data = { POSTGRES_PASSWORD = local.secret["postgres_password"] }
}

resource "kubernetes_persistent_volume_claim_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = { storage = "5Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
    labels    = { app = "postgres" }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "postgres" }
    }
    template {
      metadata {
        labels = { app = "postgres" }
      }
      spec {
        container {
          name  = "postgres"
          image = "postgres:16-alpine"
          env {
            name  = "POSTGRES_USER"
            value = "litellm"
          }
          env {
            name  = "POSTGRES_DB"
            value = "litellm"
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.postgres.metadata[0].name
            }
          }
          port {
            container_port = 5432
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.postgres.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
  }
  spec {
    selector = { app = "postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_config_map_v1" "litellm" {
  metadata {
    name      = "litellm-config"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
  }
  data = { "config.yaml" = file("${path.module}/../litellm/config.yaml") }
}

resource "kubernetes_deployment_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
    labels    = { app = "litellm" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "litellm" }
    }
    template {
      metadata {
        labels = { app = "litellm" }
        # Roll the pod when the config changes.
        annotations = { "config-sha" = sha256(kubernetes_config_map_v1.litellm.data["config.yaml"]) }
      }
      spec {
        container {
          name  = "litellm"
          image = var.litellm_image
          args  = ["--config", "/app/config/config.yaml", "--port", "4000"]
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.litellm.metadata[0].name
            }
          }
          port {
            container_port = 4000
          }
          volume_mount {
            name       = "config"
            mount_path = "/app/config"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/health/readiness"
              port = 4000
            }
            initial_delay_seconds = 20
            period_seconds        = 10
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.litellm.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_deployment_v1.postgres]
}

resource "kubernetes_service_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.ns["platform"].metadata[0].name
  }
  spec {
    selector = { app = "litellm" }
    port {
      port        = 4000
      target_port = 4000
    }
  }
}
