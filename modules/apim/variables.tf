variable "name" {
  description = "Name of the API Management instance"
  type        = string
}

variable "location" {
  description = "Primary Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "publisher_name" {
  description = "Publisher name for the APIM instance"
  type        = string
}

variable "publisher_email" {
  description = "Publisher email for the APIM instance"
  type        = string
}

variable "sku_name" {
  description = "SKU tier (Premium required for multi-region)"
  type        = string
  default     = "Premium"
}

variable "sku_capacity" {
  description = "Number of scale units in the primary region"
  type        = number
  default     = 1
}

variable "zones" {
  description = "Availability zones for the primary region (Premium only)"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "virtual_network_type" {
  description = "VNet integration type: None, External, or Internal"
  type        = string
  default     = "Internal"
}

variable "subnet_id" {
  description = "Subnet ID for the primary region VNet integration"
  type        = string
}

variable "additional_locations" {
  description = "Additional regions for multi-region DR (Premium only). Each entry deploys a gateway in that region."
  type = list(object({
    location         = string
    subnet_id        = string
    zones            = list(string)
    capacity         = optional(number, 1)
    gateway_disabled = optional(bool, false)
  }))
  default = []
}

variable "user_assigned_identity_ids" {
  description = "List of User Assigned Managed Identity IDs to associate"
  type        = list(string)
  default     = null
}

variable "enable_http2" {
  description = "Enable HTTP/2 protocol"
  type        = bool
  default     = true
}

variable "min_api_version" {
  description = "Minimum API version to enforce on management API calls"
  type        = string
  default     = null
}

variable "sign_up_enabled" {
  description = "Enable developer portal sign-up"
  type        = bool
  default     = false
}

variable "named_values" {
  description = "Map of named values (properties) to create in APIM"
  type = map(object({
    display_name         = string
    value                = optional(string)
    secret               = optional(bool, false)
    key_vault_secret_id  = optional(string)
  }))
  default = {}
}

variable "enable_diagnostics" {
  description = "Enable diagnostic settings to Log Analytics"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID for diagnostics"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
