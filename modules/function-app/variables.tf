variable "name" {
  description = "Name of the Function App"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
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
  description = "SKU name for the App Service Plan (Elastic Premium for VNet integration)"
  type        = string
  default     = "EP1"
}

variable "os_type" {
  description = "OS type for the App Service Plan"
  type        = string
  default     = "Linux"
}

variable "storage_account_name" {
  description = "Name of the storage account for the Function App"
  type        = string
}

variable "storage_account_access_key" {
  description = "Access key for the storage account"
  type        = string
  sensitive   = true
}

variable "dotnet_version" {
  description = ".NET version for the Function App runtime"
  type        = string
  default     = "8.0"
}

variable "use_dotnet_isolated_runtime" {
  description = "Whether to use the .NET isolated worker runtime"
  type        = bool
  default     = true
}

variable "always_on" {
  description = "Whether the Function App should be always on"
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = "Path for the health check endpoint"
  type        = string
  default     = "/api/healthz"
}

variable "health_check_eviction_time_in_min" {
  description = "Time in minutes after which unhealthy instances are evicted"
  type        = number
  default     = 2
}

variable "vnet_integration_subnet_id" {
  description = "Subnet ID for VNet integration"
  type        = string
  default     = null
}

variable "app_settings" {
  description = "Application settings for the Function App"
  type        = map(string)
  default     = {}
}

variable "identity_type" {
  description = "Type of managed identity (SystemAssigned, UserAssigned, or SystemAssigned, UserAssigned)"
  type        = string
  default     = "SystemAssigned"
}

variable "user_assigned_identity_ids" {
  description = "List of User Assigned Identity IDs to assign to the Function App"
  type        = list(string)
  default     = null
}

variable "application_insights_connection_string" {
  description = "Application Insights connection string"
  type        = string
  default     = ""
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

variable "zone_redundant" {
  description = "Whether the App Service Plan should be zone redundant"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
