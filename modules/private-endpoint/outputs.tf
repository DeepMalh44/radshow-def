output "id" {
  value       = azurerm_private_endpoint.this.id
  description = "The ID of the private endpoint."
}

output "name" {
  value       = azurerm_private_endpoint.this.name
  description = "The name of the private endpoint."
}

output "private_ip_address" {
  value       = azurerm_private_endpoint.this.private_service_connection[0].private_ip_address
  description = "The private IP address assigned to the private endpoint."
}

output "network_interface_id" {
  value       = azurerm_private_endpoint.this.network_interface[0].id
  description = "The ID of the network interface associated with the private endpoint."
}
