locals {
  is_premium = var.sku_name == "Premium"
  identity_type = var.user_assigned_identity_ids != null ? "SystemAssigned, UserAssigned" : "SystemAssigned"
}

resource "azurerm_api_management" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email

  sku_name = "${var.sku_name}_${var.sku_capacity}"

  zones                = local.is_premium ? var.zones : []
  virtual_network_type = var.virtual_network_type

  dynamic "virtual_network_configuration" {
    for_each = var.virtual_network_type != "None" ? [1] : []
    content {
      subnet_id = var.subnet_id
    }
  }

  # ── Multi-region DR: deploy gateways in secondary regions ──
  dynamic "additional_location" {
    for_each = local.is_premium ? var.additional_locations : []
    content {
      location         = additional_location.value.location
      capacity         = additional_location.value.capacity
      zones            = additional_location.value.zones
      gateway_disabled = additional_location.value.gateway_disabled

      dynamic "virtual_network_configuration" {
        for_each = var.virtual_network_type != "None" ? [1] : []
        content {
          subnet_id = additional_location.value.subnet_id
        }
      }
    }
  }

  identity {
    type         = local.identity_type
    identity_ids = var.user_assigned_identity_ids
  }

  protocols {
    enable_http2 = var.enable_http2
  }

  security {
    enable_backend_ssl30  = false
    enable_backend_tls10  = false
    enable_backend_tls11  = false
    enable_frontend_ssl30 = false
    enable_frontend_tls10 = false
    enable_frontend_tls11 = false

    tls_ecdhe_ecdsa_with_aes128_cbc_sha_ciphers_enabled = false
    tls_ecdhe_ecdsa_with_aes256_cbc_sha_ciphers_enabled = false
    tls_ecdhe_rsa_with_aes128_cbc_sha_ciphers_enabled   = false
    tls_ecdhe_rsa_with_aes256_cbc_sha_ciphers_enabled   = false
    tls_rsa_with_aes128_cbc_sha256_ciphers_enabled      = false
    tls_rsa_with_aes128_cbc_sha_ciphers_enabled         = false
    tls_rsa_with_aes128_gcm_sha256_ciphers_enabled      = true
    tls_rsa_with_aes256_cbc_sha256_ciphers_enabled      = false
    tls_rsa_with_aes256_cbc_sha_ciphers_enabled         = false
    tls_rsa_with_aes256_gcm_sha384_ciphers_enabled      = true
  }

  min_api_version = var.min_api_version

  sign_up {
    enabled = var.sign_up_enabled
    terms_of_service {
      enabled          = false
      consent_required = false
    }
  }

  timeouts {
    create = "3h"
    update = "3h"
    delete = "3h"
  }

  tags = var.tags
}

# ── Named Values (properties) with optional Key Vault reference ──
resource "azurerm_api_management_named_value" "this" {
  for_each = var.named_values

  name                = each.key
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  display_name        = each.value.display_name
  secret              = each.value.secret

  # Plain-text value (only when no Key Vault reference)
  value = each.value.key_vault_secret_id == null ? each.value.value : null

  # Key Vault reference
  dynamic "value_from_key_vault" {
    for_each = each.value.key_vault_secret_id != null ? [1] : []
    content {
      secret_id = each.value.key_vault_secret_id
    }
  }
}

# ── Diagnostic Settings ──
resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "${var.name}-diag"
  target_resource_id         = azurerm_api_management.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_log {
    category = "WebSocketConnectionLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
