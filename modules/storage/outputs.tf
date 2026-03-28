output "id" {
  description = "Storage account resource ID"
  value       = azurerm_storage_account.this.id
}

output "name" {
  description = "Storage account name"
  value       = azurerm_storage_account.this.name
}

output "primary_web_endpoint" {
  description = "Primary static website endpoint (used for Vue.js SPA)"
  value       = azurerm_storage_account.this.primary_web_endpoint
}

output "primary_web_host" {
  description = "Primary static website hostname (without https://)"
  value       = azurerm_storage_account.this.primary_web_host
}

output "primary_blob_endpoint" {
  description = "Primary blob service endpoint"
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "primary_access_key" {
  description = "Primary access key for the storage account"
  value       = azurerm_storage_account.this.primary_access_key
  sensitive   = true
}

output "primary_connection_string" {
  description = "Primary connection string for the storage account"
  value       = azurerm_storage_account.this.primary_connection_string
  sensitive   = true
}

output "secondary_web_endpoint" {
  description = "Secondary static website endpoint (RA-GZRS read-access DR)"
  value       = azurerm_storage_account.this.secondary_web_endpoint
}

output "secondary_blob_endpoint" {
  description = "Secondary blob service endpoint (RA-GZRS read-access DR)"
  value       = azurerm_storage_account.this.secondary_blob_endpoint
}
