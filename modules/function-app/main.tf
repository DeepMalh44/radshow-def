resource "azurerm_service_plan" "this" {
  name                = var.service_plan_name
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = var.os_type
  sku_name            = var.service_plan_sku_name

  tags = var.tags
}

resource "azurerm_linux_function_app" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.this.id

  storage_account_name       = var.storage_account_name
  storage_account_access_key = var.storage_account_access_key
  builtin_logging_enabled    = false

  https_only                    = true
  virtual_network_subnet_id     = var.vnet_integration_subnet_id

  site_config {
    always_on              = var.always_on
    health_check_path      = var.health_check_path
    ftps_state             = "Disabled"
    minimum_tls_version    = "1.2"
    http2_enabled          = true
    elastic_instance_minimum = 1

    application_stack {
      dotnet_version              = var.dotnet_version
      use_dotnet_isolated_runtime = var.use_dotnet_isolated_runtime
    }
  }

  app_settings = merge(
    var.app_settings,
    var.application_insights_connection_string != "" ? {
      APPLICATIONINSIGHTS_CONNECTION_STRING = var.application_insights_connection_string
    } : {}
  )

  identity {
    type         = var.identity_type
    identity_ids = var.user_assigned_identity_ids
  }

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "${var.name}-diag"
  target_resource_id         = azurerm_linux_function_app.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
