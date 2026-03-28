output "role_assignment_ids" {
  description = "Map of role assignment keys to their resource IDs."
  value       = { for k, v in azurerm_role_assignment.this : k => v.id }
}
