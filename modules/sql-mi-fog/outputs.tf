output "id" {
  description = "Resource ID of the failover group"
  value       = azurerm_mssql_managed_instance_failover_group.this.id
}

output "name" {
  description = "Name of the failover group"
  value       = azurerm_mssql_managed_instance_failover_group.this.name
}

output "listener_fqdn" {
  description = "Read-write listener FQDN of the failover group (always routes to current primary)"
  value = replace(
    var.primary_instance_fqdn,
    element(split(".", var.primary_instance_fqdn), 0),
    azurerm_mssql_managed_instance_failover_group.this.name
  )
}
