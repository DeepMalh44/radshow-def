resource "azurerm_redis_cache" "this" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  capacity                      = var.capacity
  family                        = var.family
  sku_name                      = var.sku_name
  non_ssl_port_enabled          = var.non_ssl_port_enabled
  minimum_tls_version           = var.minimum_tls_version
  shard_count                   = var.sku_name == "Premium" ? var.shard_count : 0
  replicas_per_primary          = var.replicas_per_primary
  zones                         = length(var.zones) > 0 ? var.zones : null
  subnet_id                     = var.subnet_id
  private_static_ip_address     = var.private_static_ip_address
  public_network_access_enabled = var.public_network_access_enabled

  redis_configuration {
    maxmemory_policy                      = var.redis_configuration.maxmemory_policy
    maxmemory_reserved                    = var.redis_configuration.maxmemory_reserved
    maxfragmentationmemory_reserved       = var.redis_configuration.maxfragmentationmemory_reserved
    active_directory_authentication_enabled = var.redis_configuration.active_directory_authentication_enabled
    rdb_backup_enabled                    = var.redis_configuration.rdb_backup_enabled
    rdb_backup_frequency                  = var.redis_configuration.rdb_backup_frequency
    rdb_storage_connection_string         = var.redis_configuration.rdb_storage_connection_string
  }

  dynamic "patch_schedule" {
    for_each = var.patch_schedules
    content {
      day_of_week        = patch_schedule.value.day_of_week
      start_hour_utc     = patch_schedule.value.start_hour_utc
      maintenance_window = patch_schedule.value.maintenance_window
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_redis_linked_server" "this" {
  count                       = var.enable_geo_replication && var.linked_cache_id != "" ? 1 : 0
  target_redis_cache_name     = azurerm_redis_cache.this.name
  resource_group_name         = var.resource_group_name
  linked_redis_cache_id       = var.linked_cache_id
  linked_redis_cache_location = var.linked_cache_location
  server_role                 = "Secondary"
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count                      = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0
  name                       = "${var.name}-diag"
  target_resource_id         = azurerm_redis_cache.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ConnectedClientList"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
