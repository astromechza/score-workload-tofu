locals {
  workload_type   = lookup(var.metadata, "workload.type", "Deployment")
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
    try(var.metadata["annotations"], {}),
    { "checksum/config" = sha256(local.stable_secret_json) }
  )

  # Flatten files from all containers into a map for easier iteration.
  # We only care about files with inline content for creating secrets.
  all_files_with_content = {
    for pair in flatten([
      for ckey, cval in var.containers : [
        for fkey, fval in try(cval.files, {}) : {
          ckey         = ckey
          fkey         = fkey
          file_content = fval.content
        } if try(fval.content, null) != null
      ]
    ]) : "${pair.ckey}-${pair.fkey}" => pair
  }

  # Flatten all external volumes from all containers into a single map,
  # assuming volume mount paths are unique across the pod.
  all_volumes = {
    for pair in flatten([
      for cval in var.containers : [
        for vkey, vval in try(cval.volumes, {}) : {
          key   = vkey
          value = vval
        }
      ]
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
    name = "${var.metadata["name"]}-${each.key}-env"
  }

  data = each.value.variables
}

resource "kubernetes_secret" "files" {
  for_each = local.all_files_with_content

  metadata {
    name = "${var.metadata["name"]}-${each.value.ckey}-${each.value.fkey}"
  }

  data = {
    (each.value.fkey) = each.value.file_content
  }
}

resource "kubernetes_deployment" "default" {
  count = local.workload_type == "Deployment" ? 1 : 0

  metadata {
    name        = var.metadata["name"]
    annotations = local.pod_annotations
    labels      = local.pod_labels
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
            resources {
              limits = {
                cpu    = try(container.value.resources.limits.cpu, null)
                memory = try(container.value.resources.limits.memory, null)
              }
              requests = {
                cpu    = try(container.value.resources.requests.cpu, null)
                memory = try(container.value.resources.requests.memory, null)
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
                    host   = try(container.value.livenessProbe.httpGet.host, null)
                    scheme = try(container.value.livenessProbe.httpGet.scheme, null)
                    dynamic "http_header" {
                      for_each = try(container.value.livenessProbe.httpGet.httpHeaders, [])
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
                    host   = try(container.value.readinessProbe.httpGet.host, null)
                    scheme = try(container.value.readinessProbe.httpGet.scheme, null)
                    dynamic "http_header" {
                      for_each = try(container.value.readinessProbe.httpGet.httpHeaders, [])
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
              for_each = { for k, v in try(container.value.files, {}) : k => v if try(v.content, null) != null }
              iterator = file
              content {
                name       = "file-${container.key}-${file.key}"
                mount_path = file.key
                read_only  = true
              }
            }
            dynamic "volume_mount" {
              for_each = try(container.value.volumes, {})
              iterator = volume
              content {
                name       = "volume-${volume.key}"
                mount_path = volume.key
                read_only  = try(volume.value.readOnly, false)
              }
            }
          }
        }
        dynamic "volume" {
          for_each = kubernetes_secret.files
          content {
            name = "file-${volume.key}"
            secret {
              secret_name = volume.value.metadata[0].name
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

resource "kubernetes_stateful_set" "default" {
  count = local.workload_type == "StatefulSet" ? 1 : 0

  metadata {
    name        = var.metadata["name"]
    annotations = local.pod_annotations
    labels      = local.pod_labels
  }

  spec {
    selector {
      match_labels = local.pod_labels
    }

    service_name = var.metadata["name"]

    template {
      metadata {
        annotations = local.pod_annotations
        labels      = local.pod_labels
      }

      spec {
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
            resources {
              limits = {
                cpu    = try(container.value.resources.limits.cpu, null)
                memory = try(container.value.resources.limits.memory, null)
              }
              requests = {
                cpu    = try(container.value.resources.requests.cpu, null)
                memory = try(container.value.resources.requests.memory, null)
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
                    host   = try(container.value.livenessProbe.httpGet.host, null)
                    scheme = try(container.value.livenessProbe.httpGet.scheme, null)
                    dynamic "http_header" {
                      for_each = try(container.value.livenessProbe.httpGet.httpHeaders, [])
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
                    host   = try(container.value.readinessProbe.httpGet.host, null)
                    scheme = try(container.value.readinessProbe.httpGet.scheme, null)
                    dynamic "http_header" {
                      for_each = try(container.value.readinessProbe.httpGet.httpHeaders, [])
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
              for_each = { for k, v in try(container.value.files, {}) : k => v if try(v.content, null) != null }
              iterator = file
              content {
                name       = "file-${container.key}-${file.key}"
                mount_path = file.key
                read_only  = true
              }
            }
            dynamic "volume_mount" {
              for_each = try(container.value.volumes, {})
              iterator = volume
              content {
                name       = "volume-${volume.key}"
                mount_path = volume.key
                read_only  = try(volume.value.readOnly, false)
              }
            }
          }
        }
        dynamic "volume" {
          for_each = kubernetes_secret.files
          content {
            name = "file-${volume.key}"
            secret {
              secret_name = volume.value.metadata[0].name
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
