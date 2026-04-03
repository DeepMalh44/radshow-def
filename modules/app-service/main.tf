resource "azurerm_service_plan" "this" {
  name                   = var.service_plan_name
  location               = var.location
  resource_group_name    = var.resource_group_name
  os_type                = var.os_type
  sku_name               = var.service_plan_sku_name
  worker_count           = var.worker_count
  zone_balancing_enabled = var.zone_redundant

  tags = var.tags
}

resource "azurerm_linux_web_app" "this" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  service_plan_id               = azurerm_service_plan.this.id
  https_only                    = true
  virtual_network_subnet_id     = var.vnet_integration_subnet_id
  public_network_access_enabled = var.public_network_access_enabled

  site_config {
    always_on                         = var.always_on
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    minimum_tls_version               = "1.2"

    application_stack {
      dotnet_version = var.dotnet_version
    }

    dynamic "ip_restriction" {
      for_each = var.ip_restrictions
      content {
        name        = ip_restriction.value.name
        priority    = ip_restriction.value.priority
        action      = ip_restriction.value.action
        ip_address  = ip_restriction.value.ip_address
        service_tag = ip_restriction.value.service_tag

        dynamic "headers" {
          for_each = ip_restriction.value.headers != null ? ip_restriction.value.headers : []
          content {
            x_forwarded_for   = headers.value.x_forwarded_for
            x_forwarded_host  = headers.value.x_forwarded_host
            x_fd_health_probe = headers.value.x_fd_health_probe
            x_azure_fdid      = headers.value.x_azure_fdid
          }
        }
      }
    }
  }

  app_settings = var.app_settings

  dynamic "connection_string" {
    for_each = var.connection_strings
    content {
      name  = connection_string.key
      type  = connection_string.value.type
      value = connection_string.value.value
    }
  }

  identity {
    type         = var.identity_type
    identity_ids = var.user_assigned_identity_ids
  }

  sticky_settings {
    app_setting_names = keys(var.app_settings)
  }

  tags = var.tags
}

resource "azurerm_linux_web_app_slot" "staging" {
  count          = var.enable_slot ? 1 : 0
  name           = var.slot_name
  app_service_id = azurerm_linux_web_app.this.id

  site_config {
    always_on                         = var.always_on
    health_check_path                 = var.health_check_path
    health_check_eviction_time_in_min = var.health_check_eviction_time_in_min
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    minimum_tls_version               = "1.2"

    application_stack {
      dotnet_version = var.dotnet_version
    }

    dynamic "ip_restriction" {
      for_each = var.ip_restrictions
      content {
        name        = ip_restriction.value.name
        priority    = ip_restriction.value.priority
        action      = ip_restriction.value.action
        ip_address  = ip_restriction.value.ip_address
        service_tag = ip_restriction.value.service_tag

        dynamic "headers" {
          for_each = ip_restriction.value.headers != null ? ip_restriction.value.headers : []
          content {
            x_forwarded_for   = headers.value.x_forwarded_for
            x_forwarded_host  = headers.value.x_forwarded_host
            x_fd_health_probe = headers.value.x_fd_health_probe
            x_azure_fdid      = headers.value.x_azure_fdid
          }
        }
      }
    }
  }

  app_settings = var.app_settings

  dynamic "connection_string" {
    for_each = var.connection_strings
    content {
      name  = connection_string.key
      type  = connection_string.value.type
      value = connection_string.value.value
    }
  }

  identity {
    type         = var.identity_type
    identity_ids = var.user_assigned_identity_ids
  }

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count                      = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0
  name                       = "tf-${var.name}-diag"
  target_resource_id         = azurerm_linux_web_app.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }

  enabled_log {
    category = "AppServiceConsoleLogs"
  }

  enabled_log {
    category = "AppServiceAppLogs"
  }

  enabled_log {
    category = "AppServicePlatformLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
