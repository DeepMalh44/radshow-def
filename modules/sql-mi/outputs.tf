output "id" {
  description = "Resource ID of the SQL Managed Instance"
  value       = azapi_resource.sql_mi.id
}

output "name" {
  description = "Name of the SQL Managed Instance"
  value       = azapi_resource.sql_mi.name
}

output "fqdn" {
  description = "Fully qualified domain name of the SQL Managed Instance"
  value       = try(azapi_resource.sql_mi.output.properties.fullyQualifiedDomainName, "")
}

output "identity_principal_id" {
  description = "Principal ID of the SQL MI system-assigned managed identity"
  value       = try(azapi_resource.sql_mi.identity.principal_id, "")
}

output "failover_group_id" {
  description = "Resource ID of the failover group (empty if not created)"
  value       = try(azurerm_mssql_managed_instance_failover_group.this[0].id, "")
}

output "failover_group_name" {
  description = "Name of the failover group (empty if not created)"
  value       = try(azurerm_mssql_managed_instance_failover_group.this[0].name, "")
}
