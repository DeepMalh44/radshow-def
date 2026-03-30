# Tests for DR automation configuration
# Validates automation module with DR runbooks and webhook support

# ── DR Runbooks Enabled ─────────────────────────────────────────────────
run "automation_dr_runbooks_enabled" {
  command = plan

  module {
    source = "../modules/automation"
  }

  variables {
    name                = "aa-test-dr-scus"
    location            = "southcentralus"
    resource_group_name = "rg-test-prd01-scus"
    enable_dr_runbooks  = true
    enable_dr_webhook   = true
    tags                = { environment = "test" }
  }

  # Verify all 7 bundled DR runbooks are created
  assert {
    condition     = length(azurerm_automation_runbook.this) == 7
    error_message = "Expected 7 DR runbooks when enable_dr_runbooks = true"
  }

  # Verify webhook is created
  assert {
    condition     = length(azurerm_automation_webhook.dr_failover) == 1
    error_message = "DR webhook should be created when enable_dr_webhook = true"
  }
}

# ── DR Runbooks Disabled ────────────────────────────────────────────────
run "automation_dr_runbooks_disabled" {
  command = plan

  module {
    source = "../modules/automation"
  }

  variables {
    name                = "aa-test-dr-dev"
    location            = "southcentralus"
    resource_group_name = "rg-test-dev01-scus"
    enable_dr_runbooks  = false
    enable_dr_webhook   = false
    tags                = { environment = "test" }
  }

  # No runbooks when disabled
  assert {
    condition     = length(azurerm_automation_runbook.this) == 0
    error_message = "No runbooks should be created when enable_dr_runbooks = false"
  }

  # No webhook when disabled
  assert {
    condition     = length(azurerm_automation_webhook.dr_failover) == 0
    error_message = "No webhook should be created when enable_dr_webhook = false"
  }
}

# ── Dual Automation Account pattern ─────────────────────────────────────
run "automation_primary_region" {
  command = plan

  module {
    source = "../modules/automation"
  }

  variables {
    name                = "aa-radshow-prd01-dr-scus"
    location            = "southcentralus"
    resource_group_name = "rg-radshow-prd01-scus"
    enable_dr_runbooks  = true
    enable_dr_webhook   = true
    tags                = { environment = "prd01", role = "dr-primary" }
  }

  assert {
    condition     = azurerm_automation_account.this.location == "southcentralus"
    error_message = "Primary AA should be in southcentralus"
  }
}

run "automation_secondary_region" {
  command = plan

  module {
    source = "../modules/automation"
  }

  variables {
    name                = "aa-radshow-prd01-dr-ncus"
    location            = "northcentralus"
    resource_group_name = "rg-radshow-prd01-ncus"
    enable_dr_runbooks  = true
    enable_dr_webhook   = true
    tags                = { environment = "prd01", role = "dr-secondary" }
  }

  assert {
    condition     = azurerm_automation_account.this.location == "northcentralus"
    error_message = "Secondary AA should be in northcentralus"
  }
}
