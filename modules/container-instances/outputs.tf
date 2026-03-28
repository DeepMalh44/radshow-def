output "id" {
  description = "The ID of the container group"
  value       = azurerm_container_group.this.id
}

output "name" {
  description = "The name of the container group"
  value       = azurerm_container_group.this.name
}

output "ip_address" {
  description = "The IP address of the container group"
  value       = azurerm_container_group.this.ip_address
}

output "fqdn" {
  description = "The FQDN of the container group"
  value       = azurerm_container_group.this.fqdn
}

output "identity_principal_id" {
  description = "The principal ID of the system-assigned managed identity"
  value       = try(azurerm_container_group.this.identity[0].principal_id, null)
}
