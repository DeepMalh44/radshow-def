output "profile_id" {
  description = "The ID of the Front Door profile"
  value       = azurerm_cdn_frontdoor_profile.this.id
}

output "profile_name" {
  description = "The name of the Front Door profile"
  value       = azurerm_cdn_frontdoor_profile.this.name
}

output "front_door_id" {
  description = "The resource GUID of the Front Door profile (used for X-Azure-FDID header validation)"
  value       = azurerm_cdn_frontdoor_profile.this.resource_guid
}

output "endpoint_ids" {
  description = "Map of endpoint names to their IDs"
  value = {
    for k, v in azurerm_cdn_frontdoor_endpoint.this : k => v.id
  }
}

output "origin_group_ids" {
  description = "Map of origin group names to their IDs"
  value = {
    for k, v in azurerm_cdn_frontdoor_origin_group.this : k => v.id
  }
}

output "waf_policy_id" {
  description = "The ID of the WAF policy (null if WAF is disabled)"
  value       = var.enable_waf ? azurerm_cdn_frontdoor_firewall_policy.this[0].id : null
}
