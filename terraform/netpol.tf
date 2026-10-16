# Ingress allow-lists. K3s enforces NetworkPolicy with its embedded kube-router controller
# (unless started with --disable-network-policy). demo/verify-controls.sh checks it from another namespace.
#
#   litellm (platform)  -> vllm (models), kb-mcp (mcp), postgres (platform)
#   kb-mcp  (mcp)       -> qdrant, embeddings (data)
#   litellm (platform)  -> embeddings (data)   for the embedding alias
# Egress is left open (model download, Cohere API); tightening it is a production step in docs/SECURITY.md.

locals {
  ns_label = "kubernetes.io/metadata.name"
}

# Default-deny ingress in every lab namespace.
resource "kubernetes_network_policy_v1" "default_deny" {
  for_each = toset(local.namespaces)
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "vllm_from_litellm" {
  metadata {
    name      = "vllm-from-litellm"
    namespace = "models"
  }
  spec {
    pod_selector {
      match_labels = { app = "vllm" }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = "platform" }
        }
        pod_selector {
          match_labels = { app = "litellm" }
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "kubernetes_network_policy_v1" "mcp_from_litellm" {
  metadata {
    name      = "mcp-from-litellm"
    namespace = "mcp"
  }
  spec {
    pod_selector {
      match_labels = { app = "kb-mcp" }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = "platform" }
        }
        pod_selector {
          match_labels = { app = "litellm" }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "kubernetes_network_policy_v1" "postgres_from_litellm" {
  metadata {
    name      = "postgres-from-litellm"
    namespace = "platform"
  }
  spec {
    pod_selector {
      match_labels = { app = "postgres" }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {
          match_labels = { app = "litellm" }
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

# The workstation reaches LiteLLM with `kubectl port-forward`, which enters the pod's own network
# namespace and is not filtered by NetworkPolicy (confirmed on kube-router: ingest uses it).
resource "kubernetes_network_policy_v1" "litellm_ingress" {
  metadata {
    name      = "litellm-ingress"
    namespace = "platform"
  }
  spec {
    pod_selector {
      match_labels = { app = "litellm" }
    }
    policy_types = ["Ingress"]
    ingress {
      ports {
        port     = "4000"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "kubernetes_network_policy_v1" "qdrant_from_mcp" {
  metadata {
    name      = "qdrant-from-mcp"
    namespace = "data"
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "qdrant" } # label set by the Qdrant chart
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = "mcp" }
        }
        pod_selector {
          match_labels = { app = "kb-mcp" }
        }
      }
      ports {
        port     = "6333"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}

resource "kubernetes_network_policy_v1" "embeddings_from_mcp_and_litellm" {
  metadata {
    name      = "embeddings-from-mcp-and-litellm"
    namespace = "data"
  }
  spec {
    pod_selector {
      match_labels = { app = "embeddings" }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = "mcp" }
        }
        pod_selector {
          match_labels = { app = "kb-mcp" }
        }
      }
      from {
        namespace_selector {
          match_labels = { (local.ns_label) = "platform" }
        }
        pod_selector {
          match_labels = { app = "litellm" }
        }
      }
      ports {
        port     = "80"
        protocol = "TCP"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.ns]
}
