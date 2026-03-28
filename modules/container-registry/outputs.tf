output "id" {
  description = "The ID of the container registry"
  value       = azurerm_container_registry.this.id
}

output "name" {
  description = "The name of the container registry"
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "The login server URL of the container registry"
  value       = azurerm_container_registry.this.login_server
}

output "admin_username" {
  description = "The admin username of the container registry"
  value       = azurerm_container_registry.this.admin_username
  sensitive   = true
}

output "admin_password" {
  description = "The admin password of the container registry"
  value       = azurerm_container_registry.this.admin_password
  sensitive   = true
}

output "identity_principal_id" {
  description = "The principal ID of the system-assigned managed identity"
  value       = azurerm_container_registry.this.identity[0].principal_id
}
