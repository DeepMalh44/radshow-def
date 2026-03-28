variable "environment_name" {
  description = "Name of the Container Apps Environment"
  type        = string
}

variable "location" {
  description = "Azure region for the Container Apps Environment"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace for diagnostics"
  type        = string
}

variable "infrastructure_subnet_id" {
  description = "Subnet ID for VNet integration of the Container Apps Environment"
  type        = string
}

variable "internal_load_balancer_enabled" {
  description = "Whether the environment only has an internal load balancer"
  type        = bool
  default     = true
}

variable "zone_redundancy_enabled" {
  description = "Whether zone redundancy is enabled for the Container Apps Environment"
  type        = bool
  default     = false
}

variable "container_apps" {
  description = "Map of Container App definitions to deploy"
  type = map(object({
    name          = string
    revision_mode = optional(string, "Single")

    ingress = optional(object({
      external_enabled = bool
      target_port      = number
      transport        = optional(string, "http")
    }))

    template = object({
      containers = list(object({
        name    = string
        image   = string
        cpu     = number
        memory  = string
        env     = optional(list(object({ name = string, value = optional(string), secret_name = optional(string) })), [])
        command = optional(list(string))
        args    = optional(list(string))
      }))
      min_replicas    = optional(number, 1)
      max_replicas    = optional(number, 3)
      revision_suffix = optional(string)
    })

    registry = optional(object({
      server   = string
      identity = string
    }))

    identity = optional(object({
      type         = string
      identity_ids = optional(list(string))
    }))

    secrets = optional(list(object({
      name  = string
      value = string
    })), [])
  }))
  default = {}
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
