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
