resource "azurerm_log_analytics_workspace" "this" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.retention_in_days
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = var.app_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = var.app_insights_application_type
  tags                = var.tags
}

resource "azurerm_monitor_action_group" "this" {
  count               = var.action_group_name != "" ? 1 : 0
  name                = var.action_group_name
  resource_group_name = var.resource_group_name
  short_name          = var.action_group_short_name
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.action_group_email_receivers
    content {
      name          = email_receiver.value.name
      email_address = email_receiver.value.email_address
    }
  }
}

resource "azurerm_monitor_metric_alert" "this" {
  for_each = var.enable_dr_alerts ? var.dr_alert_definitions : {}

  name                = each.key
  resource_group_name = var.resource_group_name
  description         = each.value.description
  severity            = each.value.severity
  frequency           = each.value.frequency
  window_size         = each.value.window_size
  scopes              = each.value.scopes
  tags                = var.tags

  criteria {
    metric_namespace = each.value.criteria.metric_namespace
    metric_name      = each.value.criteria.metric_name
    aggregation      = each.value.criteria.aggregation
    operator         = each.value.criteria.operator
    threshold        = each.value.criteria.threshold
  }

  dynamic "action" {
    for_each = var.action_group_name != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.this[0].id
    }
  }
}
