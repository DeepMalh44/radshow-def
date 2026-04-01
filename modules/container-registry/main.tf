resource "azurerm_container_registry" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = var.sku
  admin_enabled                 = var.admin_enabled
  public_network_access_enabled = var.public_network_access_enabled
  network_rule_bypass_option    = var.network_rule_bypass_option
  zone_redundancy_enabled       = var.sku == "Premium" ? var.zone_redundancy_enabled : false

  dynamic "georeplications" {
    for_each = var.sku == "Premium" ? var.georeplications : []
    content {
      location                  = georeplications.value.location
      zone_redundancy_enabled   = georeplications.value.zone_redundancy_enabled
      regional_endpoint_enabled = georeplications.value.regional_endpoint_enabled
      tags                      = var.tags
    }
  }

  dynamic "network_rule_set" {
    for_each = var.network_rule_set != null && var.sku == "Premium" ? [var.network_rule_set] : []
    content {
      default_action = network_rule_set.value.default_action

      dynamic "ip_rule" {
        for_each = network_rule_set.value.ip_rules != null ? network_rule_set.value.ip_rules : []
        content {
          action   = ip_rule.value.action
          ip_range = ip_rule.value.ip_range
        }
      }
    }
  }

  identity {
    type         = var.identity_type
    identity_ids = var.identity_type != "SystemAssigned" ? var.user_assigned_identity_ids : null
  }

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "tf-${var.name}-diag"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
