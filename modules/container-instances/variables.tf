variable "name" {
  description = "Name of the container group"
  type        = string
}

variable "location" {
  description = "Azure region for the container group"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "os_type" {
  description = "OS type for the container group"
  type        = string
  default     = "Linux"
}

variable "restart_policy" {
  description = "Restart policy for the container group"
  type        = string
  default     = "Always"
}

variable "ip_address_type" {
  description = "IP address type (Public or Private)"
  type        = string
  default     = "Private"
}

variable "subnet_ids" {
  description = "Subnet IDs for VNet integration"
  type        = list(string)
  default     = []
}

variable "dns_name_label" {
  description = "DNS name label for the container group"
  type        = string
  default     = null
}

variable "containers" {
  description = "List of container definitions"
  type = list(object({
    name   = string
    image  = string
    cpu    = number
    memory = number
    ports = optional(list(object({
      port     = number
      protocol = optional(string, "TCP")
    })), [])
    environment_variables        = optional(map(string), {})
    secure_environment_variables = optional(map(string), {})
    commands                     = optional(list(string), [])
  }))
}

variable "image_registry_credential" {
  description = "Credentials for private container registry (e.g. ACR)"
  type = object({
    server   = string
    username = string
    password = string
  })
  default   = null
  sensitive = true
}

variable "identity_type" {
  description = "Type of managed identity (SystemAssigned, UserAssigned, or SystemAssigned, UserAssigned)"
  type        = string
  default     = "SystemAssigned"
}

variable "user_assigned_identity_ids" {
  description = "List of user-assigned managed identity IDs"
  type        = list(string)
  default     = null
}

variable "tags" {
  description = "Tags to apply to the container group"
  type        = map(string)
  default     = {}
}
