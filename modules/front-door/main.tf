###############################################################################
# Front Door Profile
###############################################################################
resource "azurerm_cdn_frontdoor_profile" "this" {
  name                     = var.profile_name
  resource_group_name      = var.resource_group_name
  sku_name                 = var.sku_name
  response_timeout_seconds = var.response_timeout_seconds
  tags                     = var.tags
}

###############################################################################
# Origin Groups
###############################################################################
resource "azurerm_cdn_frontdoor_origin_group" "this" {
  for_each = var.origin_groups

  name                     = each.key
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  session_affinity_enabled = each.value.session_affinity_enabled

  restore_traffic_time_to_healed_or_new_endpoint_in_minutes = each.value.restore_traffic_time_to_healed_or_new_endpoint_in_minutes

  health_probe {
    interval_in_seconds = each.value.health_probe.interval_in_seconds
    path                = each.value.health_probe.path
    protocol            = each.value.health_probe.protocol
    request_type        = each.value.health_probe.request_type
  }

  load_balancing {
    additional_latency_in_milliseconds = each.value.load_balancing.additional_latency_in_milliseconds
    sample_size                        = each.value.load_balancing.sample_size
    successful_samples_required        = each.value.load_balancing.successful_samples_required
  }
}

###############################################################################
# Origins (priority field drives active-passive: primary=1, secondary=2)
###############################################################################
resource "azurerm_cdn_frontdoor_origin" "this" {
  for_each = var.origins

  name                           = each.key
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.this[each.value.origin_group_key].id
  enabled                        = each.value.enabled
  certificate_name_check_enabled = each.value.certificate_name_check_enabled
  host_name                      = each.value.host_name
  origin_host_header             = each.value.origin_host_header
  http_port                      = each.value.http_port
  https_port                     = each.value.https_port
  priority                       = each.value.priority
  weight                         = each.value.weight

  dynamic "private_link" {
    for_each = each.value.private_link != null ? [each.value.private_link] : []

    content {
      location               = private_link.value.location
      private_link_target_id = private_link.value.private_link_target_id
      request_message        = private_link.value.request_message
      target_type            = private_link.value.target_type
    }
  }
}

###############################################################################
# Endpoints
###############################################################################
resource "azurerm_cdn_frontdoor_endpoint" "this" {
  for_each = var.endpoints

  name                     = each.key
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  enabled                  = each.value.enabled
  tags                     = var.tags
}

###############################################################################
# Custom Domains
###############################################################################
resource "azurerm_cdn_frontdoor_custom_domain" "this" {
  for_each = var.custom_domains

  name                     = each.key
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  host_name                = each.value.host_name

  tls {
    certificate_type    = each.value.certificate_type
    minimum_tls_version = each.value.minimum_tls_version
  }
}
