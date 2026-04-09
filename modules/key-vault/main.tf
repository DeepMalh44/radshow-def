resource "azurerm_key_vault" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  enabled_for_deployment          = var.enabled_for_deployment
  enabled_for_disk_encryption     = var.enabled_for_disk_encryption
  enabled_for_template_deployment = var.enabled_for_template_deployment
  enable_rbac_authorization       = var.enable_rbac_authorization
  purge_protection_enabled        = var.purge_protection_enabled
  soft_delete_retention_days      = var.soft_delete_retention_days
  public_network_access_enabled   = var.public_network_access_enabled

  network_acls {
    bypass                     = var.network_acls.bypass
    default_action             = var.network_acls.default_action
    ip_rules                   = var.network_acls.ip_rules
    virtual_network_subnet_ids = var.network_acls.virtual_network_subnet_ids
  }

  dynamic "access_policy" {
    for_each = var.enable_rbac_authorization ? [] : var.access_policies
    content {
      tenant_id               = access_policy.value.tenant_id
      object_id               = access_policy.value.object_id
      key_permissions         = access_policy.value.key_permissions
      secret_permissions      = access_policy.value.secret_permissions
      certificate_permissions = access_policy.value.certificate_permissions
    }
  }

  tags = var.tags
}

#--------------------------------------------------------------
# Resource Lock - Prevents accidental deletion in PRD (IR-02)
#--------------------------------------------------------------
resource "azurerm_management_lock" "this" {
  count = var.enable_delete_lock ? 1 : 0

  name       = "lock-${var.name}"
  scope      = azurerm_key_vault.this.id
  lock_level = "CanNotDelete"
  notes      = "Protected resource - requires lock removal before deletion (IR-02)"
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "tf-${var.name}-diag"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

###############################################################################
# Secrets (optional – seeded at provision time for DR failover etc.)
###############################################################################
locals {
  secret_keys = nonsensitive(toset(keys(var.secrets)))
}

resource "azurerm_key_vault_secret" "this" {
  for_each = local.secret_keys

  name         = each.key
  value        = var.secrets[each.key]
  key_vault_id = azurerm_key_vault.this.id
}

###############################################################################
# Self-signed certificate for Application Gateway TLS listener
###############################################################################
resource "azurerm_key_vault_certificate" "appgw_ssl" {
  count = var.generate_appgw_cert ? 1 : 0

  name         = "appgw-ssl-cert"
  key_vault_id = azurerm_key_vault.this.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]
      subject            = "CN=appgw-${var.name_prefix}"
      validity_in_months = 12

      subject_alternative_names {
        dns_names = ["*.azurefd.net"]
      }
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }
  }
}
