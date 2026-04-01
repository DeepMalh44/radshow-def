# -------------------------------------------------------------------
# SQL Managed Instance Failover Group (standalone module)
# Separated to break circular dependency:
#   primary MI → secondary MI (dnsZonePartner) → FOG (both IDs)
# -------------------------------------------------------------------
resource "azurerm_mssql_managed_instance_failover_group" "this" {
  name                        = var.failover_group_name
  location                    = var.location
  managed_instance_id         = var.primary_instance_id
  partner_managed_instance_id = var.secondary_instance_id

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = var.failover_grace_minutes
  }
}
