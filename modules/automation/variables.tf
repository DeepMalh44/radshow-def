variable "name" {
  description = "Name of the Automation Account"
  type        = string
}

variable "location" {
  description = "Azure region for the Automation Account"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "sku_name" {
  description = "SKU of the Automation Account"
  type        = string
  default     = "Basic"
}

variable "identity_type" {
  description = "Type of managed identity (SystemAssigned, UserAssigned, or SystemAssigned, UserAssigned)"
  type        = string
  default     = "SystemAssigned"
}

variable "user_assigned_identity_ids" {
  description = "List of User Assigned Identity IDs to assign to the Automation Account"
  type        = list(string)
  default     = null
}

variable "enable_dr_runbooks" {
  description = "Enable bundled DR drill runbook scripts from modules/automation/scripts/"
  type        = bool
  default     = false
}

variable "enable_dr_webhook" {
  description = "Create a webhook for the DR failover runbook (for dual-AA alert routing)"
  type        = bool
  default     = false
}

variable "webhook_expiry_time" {
  description = "Expiry time for the DR webhook (RFC3339 format)"
  type        = string
  default     = "2027-12-31T00:00:00Z"
}

variable "webhook_default_failover_type" {
  description = "Default FailoverType parameter for webhook invocation (Planned or Forced)"
  type        = string
  default     = "Planned"
}

variable "webhook_default_action" {
  description = "Default Action parameter for webhook invocation (failover or failback)"
  type        = string
  default     = "failover"
}

variable "runbooks" {
  description = "Map of runbooks to create in the Automation Account"
  type = map(object({
    runbook_type = optional(string, "PowerShell")
    log_verbose  = optional(bool, false)
    log_progress = optional(bool, true)
    description  = optional(string, "")
    content      = optional(string)
    uri          = optional(string)
  }))
  default = {}
}

variable "schedules" {
  description = "Map of schedules to create in the Automation Account"
  type = map(object({
    frequency   = string
    interval    = optional(number)
    start_time  = optional(string)
    description = optional(string, "")
    timezone    = optional(string, "UTC")
  }))
  default = {}
}

variable "job_schedules" {
  description = "Map of job schedules linking runbooks to schedules"
  type = map(object({
    runbook_name  = string
    schedule_name = string
    parameters    = optional(map(string))
  }))
  default = {}
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for diagnostic settings"
  type        = string
  default     = ""
}

variable "enable_diagnostics" {
  description = "Enable diagnostic settings for the Automation Account"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
