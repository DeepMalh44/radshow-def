variable "name" {
  description = "Name of the Application Gateway"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the Application Gateway"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the Application Gateway"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# SKU
variable "sku_name" {
  description = "SKU name for the Application Gateway"
  type        = string
  default     = "WAF_v2"
}

variable "sku_tier" {
  description = "SKU tier for the Application Gateway"
  type        = string
  default     = "WAF_v2"
}

variable "min_capacity" {
  description = "Minimum autoscale capacity"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum autoscale capacity"
  type        = number
  default     = 2
}

# WAF
variable "enable_waf" {
  description = "Enable WAF on the Application Gateway"
  type        = bool
  default     = true
}

variable "waf_mode" {
  description = "WAF mode: Detection or Prevention"
  type        = string
  default     = "Prevention"
}

# Front Door ID for X-Azure-FDID validation (WAF custom rule)
variable "front_door_id" {
  description = "Front Door resource GUID for X-Azure-FDID header validation"
  type        = string
}

# TLS certificate
variable "key_vault_secret_id" {
  description = "Key Vault versionless secret ID for the self-signed TLS cert"
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault resource ID (for RBAC role assignment)"
  type        = string
}

# Backend targets
variable "apim_fqdn" {
  description = "APIM gateway FQDN (e.g. apim-radshow-stg01-cin.azure-api.net)"
  type        = string
}

variable "storage_web_fqdn" {
  description = "Storage static website FQDN (e.g. stradshowstg01cin.z29.web.core.windows.net)"
  type        = string
}

# Diagnostics
variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostics"
  type        = string
  default     = ""
}

variable "enable_diagnostics" {
  description = "Enable diagnostic settings"
  type        = bool
  default     = true
}
