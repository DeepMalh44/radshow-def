output "id" {
  description = "The ID of the Key Vault."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "The name of the Key Vault."
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "The URI of the Key Vault."
  value       = azurerm_key_vault.this.vault_uri
}

output "tenant_id" {
  description = "The tenant ID of the Key Vault."
  value       = azurerm_key_vault.this.tenant_id
}

output "lock_id" {
  description = "Resource ID of the management lock (empty if not enabled)"
  value       = try(azurerm_management_lock.this[0].id, "")
}

output "appgw_cert_secret_id" {
  description = "Versionless secret ID of the AppGW self-signed certificate (null if not generated)"
  value       = try(azurerm_key_vault_certificate.appgw_ssl[0].versionless_secret_id, null)
}
