output "id" {
  description = "Resource ID of the failover group"
  value       = azurerm_mssql_managed_instance_failover_group.this.id
}

output "name" {
  description = "Name of the failover group"
  value       = azurerm_mssql_managed_instance_failover_group.this.name
}
