# Qdrant (vector store) and a CPU embedding service. Both stay off the GPU node (it is tainted).

resource "helm_release" "qdrant" {
  name       = "qdrant"
  repository = "https://qdrant.github.io/qdrant-helm"
  chart      = "qdrant"
  version    = "1.19.2"
  namespace  = kubernetes_namespace_v1.ns["data"].metadata[0].name

  values = [yamlencode({
    replicaCount = 1
    persistence  = { size = "5Gi" } # default StorageClass (K3s local-path)
    # No Qdrant API key: only kb-mcp pods may reach it (netpol.tf). Service name = release name "qdrant".
  })]
}

resource "kubernetes_deployment_v1" "embeddings" {
  metadata {
    name      = "embeddings"
    namespace = kubernetes_namespace_v1.ns["data"].metadata[0].name
    labels    = { app = "embeddings" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "embeddings" }
    }
    template {
      metadata {
        labels = { app = "embeddings" }
      }
      spec {
        container {
          name  = "tei"
          image = var.tei_image
          args  = ["--model-id", var.embedding_model, "--port", "80"]
          port {
            container_port = 80
          }
          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { memory = "2Gi" }
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 80
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            failure_threshold     = 30
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "embeddings" {
  metadata {
    name      = "embeddings"
    namespace = kubernetes_namespace_v1.ns["data"].metadata[0].name
  }
  spec {
    selector = { app = "embeddings" }
    port {
      port        = 80
      target_port = 80
    }
  }
}
