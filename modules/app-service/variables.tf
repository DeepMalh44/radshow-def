variable "name" {
  description = "Name of the Linux Web App"
  type        = string
}

variable "location" {
  description = "Azure region for the resources"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "service_plan_name" {
  description = "Name of the App Service Plan"
  type        = string
}

variable "service_plan_sku_name" {
  description = "SKU name for the App Service Plan"
  type        = string
  default     = "P1v3"
}

variable "os_type" {
  description = "OS type for the App Service Plan"
  type        = string
  default     = "Linux"
}

variable "worker_count" {
  description = "Number of workers for the App Service Plan"
  type        = number
  default     = 1
}

variable "dotnet_version" {
  description = ".NET runtime version"
  type        = string
  default     = "8.0"
}

variable "always_on" {
  description = "Whether the app should be always on"
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = "Health check endpoint path"
  type        = string
  default     = "/healthz"
}

variable "vnet_integration_subnet_id" {
  description = "Subnet ID for VNet integration"
  type        = string
  default     = null
}

variable "app_settings" {
  description = "Application settings for the web app"
  type        = map(string)
  default     = {}
}

variable "connection_strings" {
  description = "Connection strings for the web app"
  type = map(object({
    type  = string
    value = string
  }))
  default = {}
}

variable "identity_type" {
  description = "Type of managed identity (SystemAssigned, UserAssigned, SystemAssigned, UserAssigned)"
  type        = string
  default     = "SystemAssigned"
}

variable "user_assigned_identity_ids" {
  description = "List of user-assigned managed identity IDs"
  type        = list(string)
  default     = null
}

variable "enable_slot" {
  description = "Whether to create a staging deployment slot for blue-green deployments"
  type        = bool
  default     = true
}

variable "slot_name" {
  description = "Name of the deployment slot"
  type        = string
  default     = "staging"
}

variable "ip_restrictions" {
  description = "List of IP restriction rules for the web app"
  type = list(object({
    name        = string
    priority    = number
    action      = string
    ip_address  = optional(string)
    service_tag = optional(string)
    headers     = optional(list(object({
      x_forwarded_for   = optional(list(string))
      x_forwarded_host  = optional(list(string))
      x_fd_health_probe = optional(list(string))
      x_azure_fdid      = optional(list(string))
    })))
  }))
  default = []
}

variable "enable_diagnostics" {
  description = "Whether to enable diagnostic settings"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for diagnostic settings"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
