output "id" {
  description = "The ID of the Automation Account"
  value       = azurerm_automation_account.this.id
}

output "name" {
  description = "The name of the Automation Account"
  value       = azurerm_automation_account.this.name
}

output "identity_principal_id" {
  description = "The Principal ID of the Automation Account's managed identity"
  value       = try(azurerm_automation_account.this.identity[0].principal_id, null)
}

output "dsc_server_endpoint" {
  description = "The DSC Server Endpoint of the Automation Account"
  value       = azurerm_automation_account.this.dsc_server_endpoint
}

output "dsc_primary_access_key" {
  description = "The DSC Primary Access Key of the Automation Account"
  value       = azurerm_automation_account.this.dsc_primary_access_key
  sensitive   = true
}

output "runbook_names" {
  description = "Names of all deployed runbooks"
  value       = [for k, v in azurerm_automation_runbook.this : v.name]
}
