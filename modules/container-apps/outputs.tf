output "environment_id" {
  description = "Resource ID of the Container Apps Environment"
  value       = azurerm_container_app_environment.this.id
}

output "environment_name" {
  description = "Name of the Container Apps Environment"
  value       = azurerm_container_app_environment.this.name
}

output "environment_default_domain" {
  description = "Default domain of the Container Apps Environment"
  value       = azurerm_container_app_environment.this.default_domain
}

output "environment_static_ip_address" {
  description = "Static IP address of the Container Apps Environment"
  value       = azurerm_container_app_environment.this.static_ip_address
}

output "container_app_ids" {
  description = "Map of Container App keys to their resource IDs"
  value       = { for k, v in azurerm_container_app.this : k => v.id }
}

output "container_app_fqdns" {
  description = "Map of Container App keys to their FQDNs"
  value       = { for k, v in azurerm_container_app.this : k => try(v.ingress[0].fqdn, null) }
}

output "container_app_latest_revision_fqdns" {
  description = "Map of Container App keys to their latest revision FQDNs"
  value       = { for k, v in azurerm_container_app.this : k => v.latest_revision_fqdn }
}
