variable "name" {
  description = "The name of the Key Vault."
  type        = string
}

variable "location" {
  description = "The Azure region where the Key Vault will be created."
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group."
  type        = string
}

variable "tenant_id" {
  description = "The Azure AD tenant ID for the Key Vault."
  type        = string
}

variable "sku_name" {
  description = "The SKU name of the Key Vault (standard or premium)."
  type        = string
  default     = "standard"
}

variable "enabled_for_deployment" {
  description = "Allow Azure VMs to retrieve certificates stored as secrets."
  type        = bool
  default     = false
}

variable "enabled_for_disk_encryption" {
  description = "Allow Azure Disk Encryption to retrieve secrets and unwrap keys."
  type        = bool
  default     = false
}

variable "enabled_for_template_deployment" {
  description = "Allow Azure Resource Manager to retrieve secrets."
  type        = bool
  default     = false
}

variable "enable_rbac_authorization" {
  description = "Use RBAC for data plane authorization instead of access policies."
  type        = bool
  default     = true
}

variable "purge_protection_enabled" {
  description = "Enable purge protection to prevent permanent deletion during retention period."
  type        = bool
  default     = true
}

variable "soft_delete_retention_days" {
  description = "The number of days that soft-deleted items are retained."
  type        = number
  default     = 90
}

variable "public_network_access_enabled" {
  description = "Whether public network access is allowed for this Key Vault."
  type        = bool
  default     = false
}

variable "network_acls" {
  description = "Network ACL configuration for the Key Vault."
  type = object({
    bypass                     = string
    default_action             = string
    ip_rules                   = list(string)
    virtual_network_subnet_ids = list(string)
  })
  default = {
    bypass                     = "AzureServices"
    default_action             = "Deny"
    ip_rules                   = []
    virtual_network_subnet_ids = []
  }
}

variable "access_policies" {
  description = "List of access policies for the Key Vault. Only used when enable_rbac_authorization is false."
  type = list(object({
    tenant_id               = string
    object_id               = string
    key_permissions         = list(string)
    secret_permissions      = list(string)
    certificate_permissions = list(string)
  }))
  default = []
}

variable "enable_diagnostics" {
  description = "Enable diagnostic settings for the Key Vault."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "The ID of the Log Analytics workspace for diagnostic logs."
  type        = string
  default     = ""
}

variable "tags" {
  description = "A map of tags to assign to the Key Vault."
  type        = map(string)
  default     = {}
}
