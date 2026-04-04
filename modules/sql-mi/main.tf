locals {
  sku_parts  = split("_", var.sku_name)
  sku_tier   = local.sku_parts[0] == "GP" ? "GeneralPurpose" : local.sku_parts[0] == "BC" ? "BusinessCritical" : "GeneralPurpose"
  sku_family = length(local.sku_parts) > 1 ? local.sku_parts[1] : "Gen5"
}

# -------------------------------------------------------------------
# SQL Managed Instance via azapi_resource
# Uses Microsoft Entra-only authentication (MCAPS policy requirement)
# -------------------------------------------------------------------
resource "azapi_resource" "sql_mi" {
  type      = "Microsoft.Sql/managedInstances@2023-08-01-preview"
  name      = var.name
  location  = var.location
  parent_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"

  identity {
    type = var.identity_type
  }

  body = {
    sku = {
      name   = var.sku_name
      tier   = local.sku_tier
      family = local.sku_family
    }
    properties = merge({
      subnetId                   = var.subnet_id
      licenseType                = var.license_type
      vCores                     = var.vcores
      storageSizeInGB            = var.storage_size_in_gb
      collation                  = var.collation
      timezoneId                 = var.timezone_id
      minimalTlsVersion          = var.minimum_tls_version
      publicDataEndpointEnabled  = var.public_data_endpoint_enabled
      proxyOverride              = var.proxy_override
      zoneRedundant              = var.zone_redundant
      maintenanceConfigurationId = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/providers/Microsoft.Maintenance/publicMaintenanceConfigurations/${var.maintenance_configuration_name}"
      administrators = {
        administratorType         = "ActiveDirectory"
        azureADOnlyAuthentication = true
        login                     = var.entra_admin_login
        sid                       = var.entra_admin_object_id
        tenantId                  = var.entra_admin_tenant_id
        principalType             = var.entra_admin_principal_type
      }
    }, var.dns_zone_partner_id != "" ? { dnsZonePartner = var.dns_zone_partner_id } : {})
  }

  tags = var.tags

  response_export_values = ["properties.fullyQualifiedDomainName", "identity"]

  timeouts {
    create = "6h"
    update = "6h"
    delete = "6h"
  }
}

data "azurerm_subscription" "current" {}

# -------------------------------------------------------------------
# Failover Group (conditional)
# -------------------------------------------------------------------
resource "azurerm_mssql_managed_instance_failover_group" "this" {
  count = var.enable_failover_group && var.secondary_instance_id != "" ? 1 : 0

  name                        = var.failover_group_name
  location                    = var.location
  managed_instance_id         = azapi_resource.sql_mi.id
  partner_managed_instance_id = var.secondary_instance_id

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = var.failover_grace_minutes
  }
}

# -------------------------------------------------------------------
# Diagnostic Settings (conditional)
# -------------------------------------------------------------------
#--------------------------------------------------------------
# Resource Lock - Prevents accidental deletion in PRD (IR-02)
#--------------------------------------------------------------
resource "azurerm_management_lock" "this" {
  count = var.enable_delete_lock ? 1 : 0

  name       = "lock-${var.name}"
  scope      = azapi_resource.sql_mi.id
  lock_level = "CanNotDelete"
  notes      = "Protected resource - requires lock removal before deletion (IR-02)"
}

resource "azurerm_monitor_diagnostic_setting" "sql_mi" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "tf-${var.name}-diag"
  target_resource_id         = azapi_resource.sql_mi.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "SQLSecurityAuditEvents"
  }

  enabled_log {
    category = "DevOpsOperationsAudit"
  }

  enabled_log {
    category = "ResourceUsageStats"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
