#--------------------------------------------------------------
# Resource Group Module
# Creates resource groups with optional management locks (IR-02)
#--------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = var.name
  location = var.location
  tags     = var.tags
}

#--------------------------------------------------------------
# Resource Lock - Prevents accidental deletion in PRD (IR-02)
#--------------------------------------------------------------
resource "azurerm_management_lock" "this" {
  count = var.enable_delete_lock ? 1 : 0

  name       = "lock-${var.name}"
  scope      = azurerm_resource_group.this.id
  lock_level = "CanNotDelete"
  notes      = "Protected resource - requires lock removal before deletion"
}
