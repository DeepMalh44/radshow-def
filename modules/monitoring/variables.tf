variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "log_analytics_sku" {
  description = "SKU of the Log Analytics workspace"
  type        = string
  default     = "PerGB2018"
}

variable "retention_in_days" {
  description = "Retention period in days for Log Analytics"
  type        = number
  default     = 90
}

variable "app_insights_name" {
  description = "Name of the Application Insights instance"
  type        = string
}

variable "app_insights_application_type" {
  description = "Application type for Application Insights"
  type        = string
  default     = "web"
}

variable "action_group_name" {
  description = "Name of the Monitor Action Group"
  type        = string
  default     = ""
}

variable "action_group_short_name" {
  description = "Short name for the Monitor Action Group"
  type        = string
  default     = ""
}

variable "action_group_email_receivers" {
  description = "List of email receivers for the action group"
  type = list(object({
    name          = string
    email_address = string
  }))
  default = []
}

variable "dr_automation_webhook_receivers" {
  description = "List of Automation Runbook receivers for dual-AA DR failover. Deploy two entries (primary + secondary AA) for resilience."
  type = list(object({
    name                  = string
    automation_account_id = string
    runbook_name          = string
    webhook_resource_id   = string
    is_global_runbook     = bool
    service_uri           = string
  }))
  default = []
}

variable "enable_dr_alerts" {
  description = "Whether to enable DR metric alerts"
  type        = bool
  default     = true
}

variable "dr_alert_definitions" {
  description = "Map of DR alert definitions"
  type = map(object({
    description = string
    severity    = number
    frequency   = string
    window_size = string
    criteria = object({
      metric_namespace = string
      metric_name      = string
      aggregation      = string
      operator         = string
      threshold        = number
    })
    scopes = list(string)
  }))
  default = {}
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "deploy_secondary_app_insights" {
  description = "Whether to deploy a secondary App Insights instance in secondary region"
  type        = bool
  default     = false
}

variable "secondary_location" {
  description = "Azure region for secondary App Insights (required when deploy_secondary_app_insights = true)"
  type        = string
  default     = ""
}

variable "secondary_app_insights_name" {
  description = "Name of the secondary Application Insights instance"
  type        = string
  default     = ""
}
