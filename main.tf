terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}

locals {
  workload_type   = lookup(coalesce(try(var.metadata.annotations, null), {}), "score.canyon.com/workload-type", "Deployment")
  pod_labels      = { app = random_id.id.hex }
  # Create a map of all secret data, keyed by a stable identifier
  all_secret_data = merge(
    { for k, v in kubernetes_secret.env : "env-${k}" => v.data },
    { for k, v in kubernetes_secret.files : "file-${k}" => v.data }
  )

  # Create a sorted list of the keys of the combined secret data
  sorted_secret_keys = sort(keys(local.all_secret_data))

  # Create a stable JSON string from the secret data by using the sorted keys
  stable_secret_json = jsonencode([
    for key in local.sorted_secret_keys : {
      key  = key
      data = local.all_secret_data[key]
    }
  ])

  pod_annotations = merge(
    coalesce(try(var.metadata.annotations, null), {}),
    var.additional_annotations,
    { "checksum/config" = sha256(local.stable_secret_json) }
  )

  create_service = var.service != null && length(coalesce(var.service.ports, {})) > 0

  # Flatten files from all containers into a map for easier iteration.
  # We only care about files with inline content for creating secrets.
  all_files_with_content = {
    for pair in flatten([
      for ckey, cval in var.containers : [
        for fkey, fval in coalesce(cval.files, {}) : {
          ckey      = ckey
          fkey      = fkey
          content   = lookup(fval, "content", null)
          is_binary = lookup(fval, "binaryContent", null) != null
          data      = coalesce(lookup(fval, "binaryContent", null), lookup(fval, "content", null))
        } if lookup(fval, "content", null) != null || lookup(fval, "binaryContent", null) != null
      ] if cval != null
    ]) : "${pair.ckey}-${sha256(pair.fkey)}" => pair
  }

  # Flatten all external volumes from all containers into a single map,
  # assuming volume mount paths are unique across the pod.
  all_volumes = {
    for pair in flatten([
      for cval in var.containers : [
        for vkey, vval in coalesce(cval.volumes, {}) : {
          key   = vkey
          value = vval
        }
      ] if cval != null
    ]) : pair.key => pair.value
  }
}

resource "random_id" "id" {
  byte_length = 8
}

resource "kubernetes_secret" "env" {
  for_each = {
    for k, v in var.containers : k => v if v.variables != null
  }

  metadata {
    name        = "${var.metadata.name}-${each.key}-env"
    namespace   = var.namespace
    annotations = var.additional_annotations
  }

  data = each.value.variables
}

resource "kubernetes_secret" "files" {
  for_each = local.all_files_with_content

  metadata {
    name        = "${var.metadata.name}-${each.key}"
    namespace   = var.namespace
    annotations = var.additional_annotations
  }

  data = {
    for k, v in { (each.value.fkey) = each.value.data } : k => v if !each.value.is_binary
  }

  binary_data = {
    for k, v in { (each.value.fkey) = each.value.data } : k => v if each.value.is_binary
  }
}

resource "kubernetes_deployment" "default" {
  count = local.workload_type == "Deployment" ? 1 : 0

  metadata {
    name        = var.metadata.name
    annotations = local.pod_annotations
    labels      = local.pod_labels
    namespace   = var.namespace
  }

  spec {
    selector {
      match_labels = local.pod_labels
    }

    template {
      metadata {
        annotations = local.pod_annotations
        labels      = local.pod_labels
      }

      spec {
        service_account_name = var.service_account_name
        security_context {
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        dynamic "container" {
          for_each = var.containers
          iterator = container
          content {
            name    = container.key
            image   = container.value.image
            command = container.value.command
            args    = container.value.args
            dynamic "env_from" {
              for_each = container.value.variables != null ? [1] : []
              content {
                secret_ref {
                  name = kubernetes_secret.env[container.key].metadata[0].name
                }
              }
            }
            security_context {
              allow_privilege_escalation = false
              read_only_root_filesystem  = true
            }
            resources {
              limits = {
                cpu    = lookup(coalesce(container.value.resources, {}), "limits", {}).cpu
                memory = lookup(coalesce(container.value.resources, {}), "limits", {}).memory
              }
              requests = {
                cpu    = lookup(coalesce(container.value.resources, {}), "requests", {}).cpu
                memory = lookup(coalesce(container.value.resources, {}), "requests", {}).memory
              }
            }
            dynamic "liveness_probe" {
              for_each = container.value.livenessProbe != null ? [1] : []
              content {
                dynamic "http_get" {
                  for_each = container.value.livenessProbe.httpGet != null ? [1] : []
                  content {
                    path   = container.value.livenessProbe.httpGet.path
                    port   = container.value.livenessProbe.httpGet.port
                    host   = lookup(container.value.livenessProbe.httpGet, "host", null)
                    scheme = lookup(container.value.livenessProbe.httpGet, "scheme", null)
                    dynamic "http_header" {
                      for_each = coalesce(container.value.livenessProbe.httpGet.httpHeaders, [])
                      iterator = header
                      content {
                        name  = header.value.name
                        value = header.value.value
                      }
                    }
                  }
                }
                dynamic "exec" {
                  for_each = container.value.livenessProbe.exec != null ? [1] : []
                  content {
                    command = container.value.livenessProbe.exec.command
                  }
                }
              }
            }
            dynamic "readiness_probe" {
              for_each = container.value.readinessProbe != null ? [1] : []
              content {
                dynamic "http_get" {
                  for_each = container.value.readinessProbe.httpGet != null ? [1] : []
                  content {
                    path   = container.value.readinessProbe.httpGet.path
                    port   = container.value.readinessProbe.httpGet.port
                    host   = lookup(container.value.readinessProbe.httpGet, "host", null)
                    scheme = lookup(container.value.readinessProbe.httpGet, "scheme", null)
                    dynamic "http_header" {
                      for_each = coalesce(container.value.readinessProbe.httpGet.httpHeaders, [])
                      iterator = header
                      content {
                        name  = header.value.name
                        value = header.value.value
                      }
                    }
                  }
                }
                dynamic "exec" {
                  for_each = container.value.readinessProbe.exec != null ? [1] : []
                  content {
                    command = container.value.readinessProbe.exec.command
                  }
                }
              }
            }
            dynamic "volume_mount" {
              for_each = { for k, v in coalesce(container.value.files, {}) : k => v if lookup(v, "content", null) != null }
              iterator = file
              content {
                name       = "file-${container.key}-${sha256(file.key)}"
                mount_path = file.key
                read_only  = true
              }
            }
            dynamic "volume_mount" {
              for_each = coalesce(container.value.volumes, {})
              iterator = volume
              content {
                name       = "volume-${volume.key}"
                mount_path = volume.key
                read_only  = coalesce(volume.value.readOnly, false)
              }
            }
          }
        }
        dynamic "volume" {
          for_each = local.all_files_with_content
          content {
            name = "file-${each.key}"
            secret {
              secret_name = kubernetes_secret.files[each.key].metadata[0].name
            }
          }
        }
        dynamic "volume" {
          for_each = local.all_volumes
          content {
            name = "volume-${volume.key}"
            persistent_volume_claim {
              claim_name = volume.value.source
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "default" {
  count = local.create_service ? 1 : 0

  metadata {
    name        = var.metadata.name
    namespace   = var.namespace
    labels      = local.pod_labels
    annotations = var.additional_annotations
  }

  spec {
    selector = local.pod_labels

    dynamic "port" {
      for_each = coalesce(var.service.ports, {})
      iterator = service_port
      content {
        name        = service_port.key
        port        = service_port.value.port
        target_port = coalesce(service_port.value.targetPort, service_port.value.port)
        protocol    = coalesce(service_port.value.protocol, "TCP")
      }
    }
  }
}

resource "kubernetes_stateful_set" "default" {
  count = local.workload_type == "StatefulSet" ? 1 : 0

  metadata {
    name        = var.metadata.name
    annotations = local.pod_annotations
    labels      = local.pod_labels
    namespace   = var.namespace
  }

  spec {
    selector {
      match_labels = local.pod_labels
    }

    service_name = var.metadata.name

    template {
      metadata {
        annotations = local.pod_annotations
        labels      = local.pod_labels
      }

      spec {
        service_account_name = var.service_account_name
        security_context {
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        dynamic "container" {
          for_each = var.containers
          iterator = container
          content {
            name    = container.key
            image   = container.value.image
            command = container.value.command
            args    = container.value.args
            dynamic "env_from" {
              for_each = container.value.variables != null ? [1] : []
              content {
                secret_ref {
                  name = kubernetes_secret.env[container.key].metadata[0].name
                }
              }
            }
            security_context {
              allow_privilege_escalation = false
              read_only_root_filesystem  = true
            }
            resources {
              limits = {
                cpu    = lookup(coalesce(container.value.resources, {}), "limits", {}).cpu
                memory = lookup(coalesce(container.value.resources, {}), "limits", {}).memory
              }
              requests = {
                cpu    = lookup(coalesce(container.value.resources, {}), "requests", {}).cpu
                memory = lookup(coalesce(container.value.resources, {}), "requests", {}).memory
              }
            }
            dynamic "liveness_probe" {
              for_each = container.value.livenessProbe != null ? [1] : []
              content {
                dynamic "http_get" {
                  for_each = container.value.livenessProbe.httpGet != null ? [1] : []
                  content {
                    path   = container.value.livenessProbe.httpGet.path
                    port   = container.value.livenessProbe.httpGet.port
                    host   = lookup(container.value.livenessProbe.httpGet, "host", null)
                    scheme = lookup(container.value.livenessProbe.httpGet, "scheme", null)
                    dynamic "http_header" {
                      for_each = coalesce(container.value.livenessProbe.httpGet.httpHeaders, [])
                      iterator = header
                      content {
                        name  = header.value.name
                        value = header.value.value
                      }
                    }
                  }
                }
                dynamic "exec" {
                  for_each = container.value.livenessProbe.exec != null ? [1] : []
                  content {
                    command = container.value.livenessProbe.exec.command
                  }
                }
              }
            }
            dynamic "readiness_probe" {
              for_each = container.value.readinessProbe != null ? [1] : []
              content {
                dynamic "http_get" {
                  for_each = container.value.readinessProbe.httpGet != null ? [1] : []
                  content {
                    path   = container.value.readinessProbe.httpGet.path
                    port   = container.value.readinessProbe.httpGet.port
                    host   = lookup(container.value.readinessProbe.httpGet, "host", null)
                    scheme = lookup(container.value.readinessProbe.httpGet, "scheme", null)
                    dynamic "http_header" {
                      for_each = coalesce(container.value.readinessProbe.httpGet.httpHeaders, [])
                      iterator = header
                      content {
                        name  = header.value.name
                        value = header.value.value
                      }
                    }
                  }
                }
                dynamic "exec" {
                  for_each = container.value.readinessProbe.exec != null ? [1] : []
                  content {
                    command = container.value.readinessProbe.exec.command
                  }
                }
              }
            }
            dynamic "volume_mount" {
              for_each = { for k, v in coalesce(container.value.files, {}) : k => v if lookup(v, "content", null) != null }
              iterator = file
              content {
                name       = "file-${container.key}-${sha256(file.key)}"
                mount_path = file.key
                read_only  = true
              }
            }
            dynamic "volume_mount" {
              for_each = coalesce(container.value.volumes, {})
              iterator = volume
              content {
                name       = "volume-${volume.key}"
                mount_path = volume.key
                read_only  = coalesce(volume.value.readOnly, false)
              }
            }
          }
        }
        dynamic "volume" {
          for_each = local.all_files_with_content
          content {
            name = "file-${each.key}"
            secret {
              secret_name = kubernetes_secret.files[each.key].metadata[0].name
            }
          }
        }
        dynamic "volume" {
          for_each = local.all_volumes
          content {
            name = "volume-${volume.key}"
            persistent_volume_claim {
              claim_name = volume.value.source
            }
          }
        }
      }
    }
  }
}
