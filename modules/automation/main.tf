locals {
  bundled_runbooks = var.enable_dr_runbooks ? {
    "Invoke-DRFailover" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "DR Failover Runbook - orchestrates SQL MI FOG switch, Front Door priority swap, Key Vault update"
      content      = file("${path.module}/scripts/Invoke-DRFailover.ps1")
      uri          = null
    }
    "DR-Check-Health" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "Pre-drill health check for all DR components"
      content      = file("${path.module}/scripts/01-Check-Health.ps1")
      uri          = null
    }
    "DR-Planned-Failover" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "Planned failover with zero data loss"
      content      = file("${path.module}/scripts/02-Planned-Failover.ps1")
      uri          = null
    }
    "DR-Unplanned-Failover" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "Unplanned failover simulation with AllowDataLoss"
      content      = file("${path.module}/scripts/03-Unplanned-Failover.ps1")
      uri          = null
    }
    "DR-Planned-Failback" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "Planned failback to primary region"
      content      = file("${path.module}/scripts/04-Planned-Failback.ps1")
      uri          = null
    }
    "DR-Validate-Failover" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "Post-failover validation of all components"
      content      = file("${path.module}/scripts/05-Validate-Failover.ps1")
      uri          = null
    }
    "DR-Capture-Evidence" = {
      runbook_type = "PowerShell"
      log_verbose  = true
      log_progress = true
      description  = "Capture DR drill evidence for compliance"
      content      = file("${path.module}/scripts/06-Capture-Evidence.ps1")
      uri          = null
    }
  } : {}

  all_runbooks = merge(local.bundled_runbooks, var.runbooks)
}

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

#--------------------------------------------------------------
# Webhook for DR Failover runbook (dual-AA alert routing)
#--------------------------------------------------------------
resource "azurerm_automation_webhook" "dr_failover" {
  count = var.enable_dr_runbooks && var.enable_dr_webhook ? 1 : 0

  name                    = "wh-${var.name}-dr-failover"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.this.name
  runbook_name            = azurerm_automation_runbook.this["Invoke-DRFailover"].name
  expiry_time             = var.webhook_expiry_time
  enabled                 = true

  parameters = {
    failovertype = var.webhook_default_failover_type
    action       = var.webhook_default_action
  }
}

resource "azurerm_automation_runbook" "this" {
  for_each = local.all_runbooks

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
