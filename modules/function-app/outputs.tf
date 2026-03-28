output "service_plan_id" {
  description = "ID of the App Service Plan"
  value       = azurerm_service_plan.this.id
}

output "function_app_id" {
  description = "ID of the Function App"
  value       = azurerm_linux_function_app.this.id
}

output "function_app_name" {
  description = "Name of the Function App"
  value       = azurerm_linux_function_app.this.name
}

output "default_hostname" {
  description = "Default hostname of the Function App"
  value       = azurerm_linux_function_app.this.default_hostname
}

output "outbound_ip_addresses" {
  description = "Comma-separated list of outbound IP addresses"
  value       = azurerm_linux_function_app.this.outbound_ip_addresses
}

output "identity_principal_id" {
  description = "Principal ID of the system-assigned managed identity"
  value       = try(azurerm_linux_function_app.this.identity[0].principal_id, null)
}
