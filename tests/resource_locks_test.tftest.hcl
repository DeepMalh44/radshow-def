# Tests for resource locks on SQL MI, APIM, and Key Vault (IR-02)
# Validates that management locks are created when enable_delete_lock = true
# and not created when enable_delete_lock = false

# ── SQL MI Lock Enabled ─────────────────────────────────────────────────
run "sql_mi_lock_enabled" {
  command = plan

  module {
    source = "../modules/sql-mi"
  }

  variables {
    name                = "sqlmi-test-prd01-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-prd01-scus"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-sqlmi"
    enable_delete_lock  = true
    tags                = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 1
    error_message = "Management lock should be created when enable_delete_lock = true"
  }
}

run "sql_mi_lock_disabled" {
  command = plan

  module {
    source = "../modules/sql-mi"
  }

  variables {
    name                = "sqlmi-test-dev01-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-dev01-scus"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-sqlmi"
    enable_delete_lock  = false
    tags                = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 0
    error_message = "Management lock should NOT be created when enable_delete_lock = false"
  }
}

# ── APIM Lock Enabled ──────────────────────────────────────────────────
run "apim_lock_enabled" {
  command = plan

  module {
    source = "../modules/apim"
  }

  variables {
    name                = "apim-test-prd01-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-prd01-scus"
    publisher_name      = "Test Publisher"
    publisher_email     = "test@example.com"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apim"
    enable_delete_lock  = true
    tags                = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 1
    error_message = "Management lock should be created when enable_delete_lock = true"
  }
}

run "apim_lock_disabled" {
  command = plan

  module {
    source = "../modules/apim"
  }

  variables {
    name                = "apim-test-dev01-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-dev01-scus"
    publisher_name      = "Test Publisher"
    publisher_email     = "test@example.com"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apim"
    enable_delete_lock  = false
    tags                = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 0
    error_message = "Management lock should NOT be created when enable_delete_lock = false"
  }
}

# ── Key Vault Lock Enabled ─────────────────────────────────────────────
run "keyvault_lock_enabled" {
  command = plan

  module {
    source = "../modules/key-vault"
  }

  variables {
    name                = "kv-test-prd01-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-prd01-scus"
    tenant_id           = "00000000-0000-0000-0000-000000000000"
    enable_delete_lock  = true
    tags                = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 1
    error_message = "Management lock should be created when enable_delete_lock = true"
  }
}

run "keyvault_lock_disabled" {
  command = plan

  module {
    source = "../modules/key-vault"
  }

  variables {
    name                = "kv-test-dev01-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-dev01-scus"
    tenant_id           = "00000000-0000-0000-0000-000000000000"
    enable_delete_lock  = false
    tags                = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 0
    error_message = "Management lock should NOT be created when enable_delete_lock = false"
  }
}

# ── Resource Group Lock (existing) ─────────────────────────────────────
run "rg_lock_enabled" {
  command = plan

  module {
    source = "../modules/resource-group"
  }

  variables {
    name               = "rg-test-prd01-scus"
    location           = "southcentralus"
    enable_delete_lock = true
    tags               = { environment = "test" }
  }

  assert {
    condition     = length(azurerm_management_lock.this) == 1
    error_message = "Management lock should be created when enable_delete_lock = true"
  }
}
