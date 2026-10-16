# NVIDIA device plugin: advertises nvidia.com/gpu on lab-gpu.
# K3s creates the "nvidia" RuntimeClass itself when it finds nvidia-container-runtime on the node,
# so we reference it rather than create it.
# The chart's default node affinity needs NFD labels or nvidia.com/gpu.present=true. We don't run NFD,
# so install-k3s-agent.sh sets that label on lab-gpu; without it the plugin never schedules.

resource "helm_release" "nvidia_device_plugin" {
  name             = "nvdp"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.20.1"
  namespace        = "nvidia-device-plugin"
  create_namespace = true

  values = [yamlencode({
    runtimeClassName = "nvidia"
    nodeSelector     = { gpu = "true" }
    tolerations = [{
      key      = "nvidia.com/gpu"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
  })]
}
