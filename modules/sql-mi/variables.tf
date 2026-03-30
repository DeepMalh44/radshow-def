variable "name" {
  description = "Name of the primary SQL Managed Instance"
  type        = string
}

variable "location" {
  description = "Azure region for the SQL Managed Instance"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "subnet_id" {
  description = "Resource ID of the delegated subnet for SQL MI"
  type        = string
}

variable "administrator_login" {
  description = "Administrator login name for the SQL MI (ignored if entra_only_auth = true)"
  type        = string
  default     = ""
}

variable "administrator_login_password" {
  description = "Administrator login password for the SQL MI (ignored if entra_only_auth = true)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "entra_only_auth" {
  description = "Whether to use Microsoft Entra-only authentication (required by MCAPS policy)"
  type        = bool
  default     = true
}

variable "entra_admin_login" {
  description = "Display name / login of the Entra admin for SQL MI"
  type        = string
  default     = ""
}

variable "entra_admin_object_id" {
  description = "Object ID of the Entra admin user or group"
  type        = string
  default     = ""
}

variable "entra_admin_tenant_id" {
  description = "Tenant ID for the Entra admin"
  type        = string
  default     = ""
}

variable "entra_admin_principal_type" {
  description = "Principal type for the Entra admin (User, Group, Application)"
  type        = string
  default     = "User"
}

variable "sku_name" {
  description = "SKU name for the SQL MI (e.g. GP_Gen5, BC_Gen5)"
  type        = string
  default     = "GP_Gen5"
}

variable "vcores" {
  description = "Number of vCores for the SQL MI"
  type        = number
  default     = 4
}

variable "storage_size_in_gb" {
  description = "Storage size in GB for the SQL MI"
  type        = number
  default     = 32
}

variable "license_type" {
  description = "License type: LicenseIncluded or BasePrice"
  type        = string
  default     = "BasePrice"
}

variable "timezone_id" {
  description = "Timezone ID for the SQL MI"
  type        = string
  default     = "UTC"
}

variable "collation" {
  description = "Collation for the SQL MI"
  type        = string
  default     = "SQL_Latin1_General_CP1_CI_AS"
}

variable "minimum_tls_version" {
  description = "Minimum TLS version enforced"
  type        = string
  default     = "1.2"
}

variable "public_data_endpoint_enabled" {
  description = "Whether the public data endpoint is enabled"
  type        = bool
  default     = false
}

variable "proxy_override" {
  description = "Connection type: Proxy, Redirect, or Default"
  type        = string
  default     = "Redirect"
}

variable "zone_redundant" {
  description = "Whether zone redundancy is enabled"
  type        = bool
  default     = false
}

variable "maintenance_configuration_name" {
  description = "Maintenance configuration name"
  type        = string
  default     = "SQL_Default"
}

variable "identity_type" {
  description = "Identity type for the SQL MI (SystemAssigned, UserAssigned, etc.)"
  type        = string
  default     = "SystemAssigned"
}

variable "enable_failover_group" {
  description = "Whether to create a failover group"
  type        = bool
  default     = false
}

variable "failover_group_name" {
  description = "Name of the failover group"
  type        = string
  default     = ""
}

variable "secondary_instance_id" {
  description = "Resource ID of the partner/secondary SQL Managed Instance"
  type        = string
  default     = ""
}

variable "failover_grace_minutes" {
  description = "Grace period in minutes before automatic failover (5 min per Tier 1 RTO/RPO requirements)"
  type        = number
  default     = 5
}

variable "enable_diagnostics" {
  description = "Whether to enable diagnostic settings"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace for diagnostics"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "enable_delete_lock" {
  description = "Enable CanNotDelete lock on the SQL MI (recommended for PRD per IR-02)"
  type        = bool
  default     = false
}
