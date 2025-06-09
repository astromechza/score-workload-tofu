output "humanitec_metadata" {
  description = "Metadata for Humanitec."
  value = merge(
    {
      "Kubernetes-Namespace" = var.namespace
    },
    var.service != null ? { "Kubernetes-Service" = kubernetes_service.default[0].metadata[0].name } : {},
    local.workload_type == "Deployment" ?
    { "Kubernetes-Deployment" = kubernetes_deployment.default[0].metadata[0].name } :
    { "Kubernetes-StatefulSet" = kubernetes_stateful_set.default[0].metadata[0].name }
  )
}
