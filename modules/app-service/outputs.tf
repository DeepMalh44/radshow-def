output "service_plan_id" {
  description = "ID of the App Service Plan"
  value       = azurerm_service_plan.this.id
}

output "app_id" {
  description = "ID of the Linux Web App"
  value       = azurerm_linux_web_app.this.id
}

output "app_name" {
  description = "Name of the Linux Web App"
  value       = azurerm_linux_web_app.this.name
}

output "default_hostname" {
  description = "Default hostname of the Linux Web App"
  value       = azurerm_linux_web_app.this.default_hostname
}

output "outbound_ip_addresses" {
  description = "Outbound IP addresses of the Linux Web App"
  value       = azurerm_linux_web_app.this.outbound_ip_addresses
}

output "identity_principal_id" {
  description = "Principal ID of the managed identity"
  value       = azurerm_linux_web_app.this.identity[0].principal_id
}

output "slot_id" {
  description = "ID of the staging deployment slot"
  value       = var.enable_slot ? azurerm_linux_web_app_slot.staging[0].id : null
}

output "slot_name" {
  description = "Name of the staging deployment slot"
  value       = var.enable_slot ? azurerm_linux_web_app_slot.staging[0].name : null
}

output "slot_default_hostname" {
  description = "Default hostname of the staging deployment slot"
  value       = var.enable_slot ? azurerm_linux_web_app_slot.staging[0].default_hostname : null
}
