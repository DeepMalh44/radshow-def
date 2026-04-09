###############################################################################
# Application Gateway with WAF_v2
# URL path routing: /api/* → APIM, /* → Storage SPA
# NSG-locked to AzureFrontDoor.Backend + X-Azure-FDID WAF validation
###############################################################################

#--------------------------------------------------------------
# Public IP (required for WAF_v2 SKU)
#--------------------------------------------------------------
resource "azurerm_public_ip" "this" {
  name                = "pip-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

#--------------------------------------------------------------
# User-Assigned Identity (for Key Vault certificate access)
#--------------------------------------------------------------
resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

#--------------------------------------------------------------
# RBAC: Grant identity Key Vault Secrets User on the KV
# Allows AppGW to pull TLS certificate at runtime
#--------------------------------------------------------------
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

#--------------------------------------------------------------
# WAF Policy (OWASP 3.2 + X-Azure-FDID custom rule)
#--------------------------------------------------------------
resource "azurerm_web_application_firewall_policy" "this" {
  count = var.enable_waf ? 1 : 0

  name                = "waf-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = var.waf_mode
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  # Block requests that do NOT have the correct Front Door ID header
  custom_rules {
    name      = "BlockNonFrontDoorTraffic"
    priority  = 1
    rule_type = "MatchRule"
    action    = "Block"

    match_conditions {
      match_variables {
        variable_name = "RequestHeaders"
        selector      = "X-Azure-FDID"
      }
      operator           = "Equal"
      negation_condition = true
      match_values       = [var.front_door_id]
    }
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

#--------------------------------------------------------------
# Application Gateway
#--------------------------------------------------------------
locals {
  frontend_ip_name    = "feip-public"
  frontend_port_name  = "feport-https"
  listener_name       = "listener-https"
  ssl_cert_name       = "appgw-ssl"
  url_path_map_name   = "upm-routing"
  bp_apim_name        = "bp-apim"
  bp_spa_name         = "bp-spa"
  bhs_apim_name       = "bhs-apim"
  bhs_spa_name        = "bhs-spa"
  probe_apim_name     = "probe-apim"
  probe_spa_name      = "probe-spa"
  routing_rule_name   = "rule-path-routing"
}

resource "azurerm_application_gateway" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
  firewall_policy_id  = var.enable_waf ? azurerm_web_application_firewall_policy.this[0].id : null

  sku {
    name = var.sku_name
    tier = var.sku_tier
  }

  autoscale_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  gateway_ip_configuration {
    name      = "gw-ip-config"
    subnet_id = var.subnet_id
  }

  #--- Frontend ---
  frontend_ip_configuration {
    name                 = local.frontend_ip_name
    public_ip_address_id = azurerm_public_ip.this.id
  }

  frontend_port {
    name = local.frontend_port_name
    port = 443
  }

  #--- SSL Certificate from Key Vault ---
  ssl_certificate {
    name                = local.ssl_cert_name
    key_vault_secret_id = var.key_vault_secret_id
  }

  #--- HTTPS Listener ---
  http_listener {
    name                           = local.listener_name
    frontend_ip_configuration_name = local.frontend_ip_name
    frontend_port_name             = local.frontend_port_name
    protocol                       = "Https"
    ssl_certificate_name           = local.ssl_cert_name
  }

  #--- Backend Address Pools ---
  backend_address_pool {
    name  = local.bp_apim_name
    fqdns = [var.apim_fqdn]
  }

  backend_address_pool {
    name  = local.bp_spa_name
    fqdns = [var.storage_web_fqdn]
  }

  #--- Backend HTTP Settings ---
  backend_http_settings {
    name                  = local.bhs_apim_name
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
    host_name             = var.apim_fqdn
    probe_name            = local.probe_apim_name
  }

  backend_http_settings {
    name                  = local.bhs_spa_name
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 30
    host_name             = var.storage_web_fqdn
    probe_name            = local.probe_spa_name
  }

  #--- Health Probes ---
  probe {
    name                = local.probe_apim_name
    protocol            = "Https"
    path                = "/api/healthz"
    host                = var.apim_fqdn
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
  }

  probe {
    name                = local.probe_spa_name
    protocol            = "Https"
    path                = "/index.html"
    host                = var.storage_web_fqdn
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
  }

  #--- URL Path Map: /api/* → APIM, default → SPA ---
  url_path_map {
    name                               = local.url_path_map_name
    default_backend_address_pool_name  = local.bp_spa_name
    default_backend_http_settings_name = local.bhs_spa_name

    path_rule {
      name                       = "api-path"
      paths                      = ["/api/*"]
      backend_address_pool_name  = local.bp_apim_name
      backend_http_settings_name = local.bhs_apim_name
    }
  }

  #--- Request Routing Rule ---
  request_routing_rule {
    name               = local.routing_rule_name
    priority           = 1
    rule_type          = "PathBasedRouting"
    http_listener_name = local.listener_name
    url_path_map_name  = local.url_path_map_name
  }

  depends_on = [azurerm_role_assignment.kv_secrets_user]
}

#--------------------------------------------------------------
# Diagnostics
#--------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics && var.log_analytics_workspace_id != "" ? 1 : 0

  name                       = "diag-${var.name}"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }

  enabled_log {
    category = "ApplicationGatewayFirewallLog"
  }

  enabled_log {
    category = "ApplicationGatewayPerformanceLog"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
