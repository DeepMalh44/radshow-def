resource "azurerm_storage_account" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  account_tier                  = var.account_tier
  account_replication_type      = var.account_replication_type
  account_kind                  = var.account_kind
  access_tier                   = var.access_tier
  min_tls_version               = var.min_tls_version
  public_network_access_enabled = var.public_network_access_enabled
  https_traffic_only_enabled    = var.https_traffic_only_enabled
  shared_access_key_enabled     = var.shared_access_key_enabled

  allow_nested_items_to_be_public = var.allow_nested_items_to_be_public

  dynamic "static_website" {
    for_each = var.enable_static_website ? [1] : []
    content {
      index_document     = var.static_website_index_document
      error_404_document = var.static_website_error_404_document
    }
  }

  dynamic "blob_properties" {
    for_each = length(var.blob_cors_rules) > 0 ? [1] : []
    content {
      dynamic "cors_rule" {
        for_each = var.blob_cors_rules
        content {
          allowed_headers    = cors_rule.value.allowed_headers
          allowed_methods    = cors_rule.value.allowed_methods
          allowed_origins    = cors_rule.value.allowed_origins
          exposed_headers    = cors_rule.value.exposed_headers
          max_age_in_seconds = cors_rule.value.max_age_in_seconds
        }
      }
    }
  }

  network_rules {
    default_action             = var.network_rules.default_action
    bypass                     = var.network_rules.bypass
    ip_rules                   = var.network_rules.ip_rules
    virtual_network_subnet_ids = var.network_rules.virtual_network_subnet_ids
  }

  tags = var.tags
}

resource "azurerm_storage_container" "this" {
  # Exclude $web when static_website is enabled — Azure creates it automatically
  for_each = { for k, v in var.containers : k => v if !(k == "$web" && var.enable_static_website) }

  name                  = each.key
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = each.value.container_access_type
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "${var.name}-blob-diag"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  metric {
    category = "Transaction"
    enabled  = true
  }
}
