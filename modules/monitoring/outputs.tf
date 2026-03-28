output "log_analytics_workspace_id" {
  description = "ID of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_primary_shared_key" {
  description = "Primary shared key of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.this.primary_shared_key
  sensitive   = true
}

output "app_insights_id" {
  description = "ID of the Application Insights instance"
  value       = azurerm_application_insights.this.id
}

output "app_insights_instrumentation_key" {
  description = "Instrumentation key of the Application Insights instance"
  value       = azurerm_application_insights.this.instrumentation_key
  sensitive   = true
}

output "app_insights_connection_string" {
  description = "Connection string of the Application Insights instance"
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "action_group_id" {
  description = "ID of the Monitor Action Group"
  value       = var.action_group_name != "" ? azurerm_monitor_action_group.this[0].id : null
}
