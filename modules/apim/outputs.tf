output "id" {
  description = "Resource ID of the API Management instance"
  value       = azurerm_api_management.this.id
}

output "name" {
  description = "Name of the API Management instance"
  value       = azurerm_api_management.this.name
}

output "gateway_url" {
  description = "Gateway (proxy) URL"
  value       = azurerm_api_management.this.gateway_url
}

output "gateway_regional_url" {
  description = "Regional gateway URL for the primary region"
  value       = azurerm_api_management.this.gateway_regional_url
}

output "gateway_secondary_regional_url" {
  description = "Regional gateway URL for the first additional (secondary) region"
  value       = length(var.additional_locations) > 0 ? "https://${azurerm_api_management.this.name}-${var.additional_locations[0].location}-01.regional.azure-api.net" : null
}

output "management_api_url" {
  description = "Management API endpoint URL"
  value       = azurerm_api_management.this.management_api_url
}

output "portal_url" {
  description = "Publisher portal URL"
  value       = azurerm_api_management.this.portal_url
}

output "developer_portal_url" {
  description = "Developer portal URL"
  value       = azurerm_api_management.this.developer_portal_url
}

output "public_ip_addresses" {
  description = "Public IP addresses of the APIM instance (all regions)"
  value       = azurerm_api_management.this.public_ip_addresses
}

output "private_ip_addresses" {
  description = "Private IP addresses of the APIM instance (all regions)"
  value       = azurerm_api_management.this.private_ip_addresses
}

output "identity_principal_id" {
  description = "Principal ID of the SystemAssigned managed identity"
  value       = try(azurerm_api_management.this.identity[0].principal_id, null)
}

output "lock_id" {
  description = "Resource ID of the management lock (empty if not enabled)"
  value       = try(azurerm_management_lock.this[0].id, "")
}

output "identity_tenant_id" {
  description = "Tenant ID of the SystemAssigned managed identity"
  value       = try(azurerm_api_management.this.identity[0].tenant_id, null)
}
