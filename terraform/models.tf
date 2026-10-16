# vLLM on the GPU node. Only LiteLLM may reach it (see netpol.tf).

resource "kubernetes_persistent_volume_claim_v1" "hf_cache" {
  metadata {
    name      = "hf-cache"
    namespace = kubernetes_namespace_v1.ns["models"].metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path" # K3s default; binds on the node where the pod lands
    resources {
      requests = { storage = "30Gi" }
    }
  }
  wait_until_bound = false # local-path uses WaitForFirstConsumer
}

resource "kubernetes_deployment_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace_v1.ns["models"].metadata[0].name
    labels    = { app = "vllm" }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # one GPU: the old pod must release it before the new one starts
    }
    selector {
      match_labels = { app = "vllm" }
    }
    template {
      metadata {
        labels = { app = "vllm" }
      }
      spec {
        runtime_class_name = "nvidia"
        node_selector      = { gpu = "true" }
        # The Service is called "vllm", so Kubernetes would inject VLLM_PORT=tcp://<ip>:8000 into the pod,
        # which vLLM reads as its own setting and refuses to start. Turn the legacy service env vars off.
        enable_service_links = false
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        container {
          name  = "vllm"
          image = var.vllm_image
          # The image's entrypoint is `vllm serve`; the model is its first positional argument.
          args = [
            var.vllm_model,
            "--served-model-name", "local-private",
            "--max-model-len", "4096",
            "--gpu-memory-utilization", "0.85",
            # Tool calling for Qwen2.5 uses the Hermes parser.
            "--enable-auto-tool-choice",
            "--tool-call-parser", "hermes",
          ]
          port {
            container_port = 8000
          }
          resources {
            limits = { "nvidia.com/gpu" = "1" }
          }
          volume_mount {
            name       = "hf-cache"
            mount_path = "/root/.cache/huggingface"
          }
          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            failure_threshold     = 60 # first start downloads the model
          }
        }
        volume {
          name = "hf-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.hf_cache.metadata[0].name
          }
        }
        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "2Gi"
          }
        }
      }
    }
  }
  # The first start downloads the model, and the pod stays Pending until lab-gpu has joined,
  # so don't block `terraform apply` on the rollout.
  wait_for_rollout = false
  depends_on       = [helm_release.nvidia_device_plugin]
}

resource "kubernetes_service_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace_v1.ns["models"].metadata[0].name
  }
  spec {
    selector = { app = "vllm" }
    port {
      port        = 8000
      target_port = 8000
    }
  }
}
