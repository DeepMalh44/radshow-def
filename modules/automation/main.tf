resource "azurerm_automation_account" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name
  tags                = var.tags

  identity {
    type         = var.identity_type
    identity_ids = var.user_assigned_identity_ids
  }
}

resource "azurerm_automation_runbook" "this" {
  for_each = var.runbooks

  name                    = each.key
  location                = azurerm_automation_account.this.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.this.name
  runbook_type            = each.value.runbook_type
  log_verbose             = each.value.log_verbose
  log_progress            = each.value.log_progress
  description             = each.value.description
  tags                    = var.tags

  content = each.value.content

  dynamic "publish_content_link" {
    for_each = each.value.uri != null ? [each.value.uri] : []
    content {
      uri = publish_content_link.value
    }
  }
}

resource "azurerm_automation_schedule" "this" {
  for_each = var.schedules

  name                    = each.key
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = each.value.frequency
  interval                = each.value.interval
  start_time              = each.value.start_time
  description             = each.value.description
  timezone                = each.value.timezone
}

resource "azurerm_automation_job_schedule" "this" {
  for_each = var.job_schedules

  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.this.name
  runbook_name            = azurerm_automation_runbook.this[each.value.runbook_name].name
  schedule_name           = azurerm_automation_schedule.this[each.value.schedule_name].name
  parameters              = each.value.parameters
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "${var.name}-diag"
  target_resource_id         = azurerm_automation_account.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "JobLogs"
  }

  enabled_log {
    category = "JobStreams"
  }

  enabled_log {
    category = "DscNodeStatus"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
