variable "name" {
  description = "Name of the Azure Container Registry"
  type        = string
}

variable "location" {
  description = "Primary Azure region for the container registry"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "sku" {
  description = "SKU for the container registry. Premium is required for geo-replication"
  type        = string
  default     = "Premium"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "SKU must be Basic, Standard, or Premium. Premium is required for geo-replication."
  }
}

variable "admin_enabled" {
  description = "Whether the admin user is enabled"
  type        = bool
  default     = false
}

variable "public_network_access_enabled" {
  description = "Whether public network access is enabled"
  type        = bool
  default     = false
}

variable "network_rule_bypass_option" {
  description = "Whether to allow trusted Azure services to bypass network rules. AzureServices or None."
  type        = string
  default     = "AzureServices"
}

variable "zone_redundancy_enabled" {
  description = "Whether zone redundancy is enabled for the primary region (Premium SKU only)"
  type        = bool
  default     = false
}

variable "georeplications" {
  description = "List of geo-replication configurations for DR. Requires Premium SKU"
  type = list(object({
    location                  = string
    zone_redundancy_enabled   = optional(bool, false)
    regional_endpoint_enabled = optional(bool, true)
  }))
  default = []
}

variable "network_rule_set" {
  description = "Network rule set for the container registry"
  type = object({
    default_action = string
    ip_rules = optional(list(object({
      action   = string
      ip_range = string
    })), [])
    virtual_network_rules = optional(list(object({
      action    = string
      subnet_id = string
    })), [])
  })
  default = null
}

variable "identity_type" {
  description = "Type of managed identity for the container registry"
  type        = string
  default     = "SystemAssigned"

  validation {
    condition     = contains(["SystemAssigned", "UserAssigned", "SystemAssigned, UserAssigned"], var.identity_type)
    error_message = "Identity type must be SystemAssigned, UserAssigned, or 'SystemAssigned, UserAssigned'."
  }
}

variable "user_assigned_identity_ids" {
  description = "List of user-assigned managed identity IDs (required when identity_type includes UserAssigned)"
  type        = list(string)
  default     = null
}

variable "enable_diagnostics" {
  description = "Whether to enable diagnostic settings"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostic settings"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to the container registry"
  type        = map(string)
  default     = {}
}
