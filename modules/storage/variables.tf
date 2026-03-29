variable "name" {
  description = "Globally unique name for the storage account"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "Storage account name must be 3-24 characters, lowercase letters and numbers only."
  }
}

variable "location" {
  description = "Azure region for the storage account"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "account_tier" {
  description = "Performance tier (Standard or Premium)"
  type        = string
  default     = "Standard"
}

variable "account_replication_type" {
  description = "Replication type - RA-GZRS for geo-redundant DR with read access to secondary"
  type        = string
  default     = "RAGZRS"
}

variable "account_kind" {
  description = "Kind of storage account"
  type        = string
  default     = "StorageV2"
}

variable "access_tier" {
  description = "Default access tier for blob storage"
  type        = string
  default     = "Hot"
}

variable "min_tls_version" {
  description = "Minimum TLS version enforced"
  type        = string
  default     = "TLS1_2"
}

variable "public_network_access_enabled" {
  description = "Whether public network access is allowed"
  type        = bool
  default     = false
}

variable "https_traffic_only_enabled" {
  description = "Force HTTPS traffic only"
  type        = bool
  default     = true
}

variable "shared_access_key_enabled" {
  description = "Whether shared access key authorization is permitted"
  type        = bool
  default     = true
}

variable "allow_nested_items_to_be_public" {
  description = "Allow or disallow nested items within this account to opt into being public"
  type        = bool
  default     = false
}

variable "enable_static_website" {
  description = "Enable static website hosting (for Vue.js SPA)"
  type        = bool
  default     = false
}

variable "static_website_index_document" {
  description = "Index document for static website"
  type        = string
  default     = "index.html"
}

variable "static_website_error_404_document" {
  description = "Error 404 document for static website - set to index.html for SPA routing"
  type        = string
  default     = "index.html"
}

variable "containers" {
  description = "Map of storage containers to create"
  type = map(object({
    container_access_type = optional(string, "private")
  }))
  default = {}
}

variable "blob_cors_rules" {
  description = "CORS rules for blob service"
  type = list(object({
    allowed_headers    = list(string)
    allowed_methods    = list(string)
    allowed_origins    = list(string)
    exposed_headers    = list(string)
    max_age_in_seconds = number
  }))
  default = []
}

variable "network_rules" {
  description = "Network rules for the storage account"
  type = object({
    default_action             = optional(string, "Deny")
    bypass                     = optional(list(string), ["AzureServices"])
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = {}
}

variable "enable_diagnostics" {
  description = "Enable diagnostic settings for blob storage"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostics"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
