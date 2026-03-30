# Module validation tests
# Validates that all modules compile without errors using terraform validate

run "validate_resource_group" {
  command = plan

  module {
    source = "../modules/resource-group"
  }

  variables {
    name     = "rg-validate-test"
    location = "southcentralus"
    tags     = { test = "true" }
  }

  assert {
    condition     = azurerm_resource_group.this.name == "rg-validate-test"
    error_message = "Resource group name should match input"
  }
}

run "validate_key_vault" {
  command = plan

  module {
    source = "../modules/key-vault"
  }

  variables {
    name                = "kv-validate-test"
    location            = "southcentralus"
    resource_group_name = "rg-validate-test"
    tenant_id           = "00000000-0000-0000-0000-000000000000"
    tags                = { test = "true" }
  }

  assert {
    condition     = azurerm_key_vault.this.name == "kv-validate-test"
    error_message = "Key Vault name should match input"
  }

  assert {
    condition     = azurerm_key_vault.this.purge_protection_enabled == true
    error_message = "Purge protection should be enabled by default"
  }

  assert {
    condition     = azurerm_key_vault.this.enable_rbac_authorization == true
    error_message = "RBAC authorization should be enabled by default"
  }
}

run "validate_monitoring" {
  command = plan

  module {
    source = "../modules/monitoring"
  }

  variables {
    log_analytics_workspace_name = "law-validate-test"
    location                     = "southcentralus"
    resource_group_name          = "rg-validate-test"
    app_insights_name            = "appi-validate-test"
    tags                         = { test = "true" }
  }

  assert {
    condition     = azurerm_log_analytics_workspace.this.name == "law-validate-test"
    error_message = "Log Analytics workspace name should match input"
  }
}

run "validate_automation" {
  command = plan

  module {
    source = "../modules/automation"
  }

  variables {
    name                = "aa-validate-test"
    location            = "southcentralus"
    resource_group_name = "rg-validate-test"
    tags                = { test = "true" }
  }

  assert {
    condition     = azurerm_automation_account.this.name == "aa-validate-test"
    error_message = "Automation Account name should match input"
  }

  assert {
    condition     = azurerm_automation_account.this.sku_name == "Basic"
    error_message = "Default SKU should be Basic"
  }
}

run "validate_storage" {
  command = plan

  module {
    source = "../modules/storage"
  }

  variables {
    name                = "stvalidatetest"
    location            = "southcentralus"
    resource_group_name = "rg-validate-test"
    tags                = { test = "true" }
  }

  assert {
    condition     = azurerm_storage_account.this.name == "stvalidatetest"
    error_message = "Storage account name should match input"
  }
}
