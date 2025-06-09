variable "metadata" {
  type = map(any)
  description = "The metadata section of the Score file."
}

variable "containers" {
  type = map(object({
    image = string
    command = optional(list(string))
    args = optional(list(string))
    variables = optional(map(string))
    files = optional(map(object({
      source = optional(string)
      content = optional(string)
      binaryContent = optional(string)
      mode = optional(string)
      noExpand = optional(bool)
    })))
    volumes = optional(map(object({
      source = string
      path = optional(string)
      readOnly = optional(bool)
    })))
    resources = optional(object({
      limits = optional(object({
        memory = optional(string)
        cpu = optional(string)
      }))
      requests = optional(object({
        memory = optional(string)
        cpu = optional(string)
      }))
    }))
    livenessProbe = optional(object({
      httpGet = optional(object({
        host = optional(string)
        scheme = optional(string)
        path = string
        port = number
        httpHeaders = optional(list(object({
          name = string
          value = string
        })))
      }))
      exec = optional(object({
        command = list(string)
      }))
    }))
    readinessProbe = optional(object({
      httpGet = optional(object({
        host = optional(string)
        scheme = optional(string)
        path = string
        port = number
        httpHeaders = optional(list(object({
          name = string
          value = string
        })))
      }))
      exec = optional(object({
        command = list(string)
      }))
    }))
  }))
  description = "The containers section of the Score file."
}

variable "service" {
  type = object({
    ports = optional(map(object({
      port = number
      protocol = optional(string)
      targetPort = optional(number)
    })))
  })
  description = "The service section of the Score file."
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to deploy the resources into."
}
