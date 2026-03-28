variable "role_assignments" {
  description = "Map of RBAC role assignments to create."
  type = map(object({
    scope                = string
    role_definition_name = string
    principal_id         = string
    principal_type       = optional(string, "ServicePrincipal")
    description          = optional(string, "")
    condition            = optional(string, null)
    condition_version    = optional(string, null)
  }))
  default = {}
}
