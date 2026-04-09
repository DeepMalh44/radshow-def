output "public_ip_address" {
  description = "Public IP address of the Application Gateway"
  value       = azurerm_public_ip.this.ip_address
}

output "application_gateway_id" {
  description = "Resource ID of the Application Gateway"
  value       = azurerm_application_gateway.this.id
}

output "identity_principal_id" {
  description = "Principal ID of the user-assigned managed identity"
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "name" {
  description = "Name of the Application Gateway"
  value       = azurerm_application_gateway.this.name
}

output "public_ip_id" {
  description = "Resource ID of the public IP"
  value       = azurerm_public_ip.this.id
}
