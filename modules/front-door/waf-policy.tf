###############################################################################
# WAF Policy
###############################################################################
resource "azurerm_cdn_frontdoor_firewall_policy" "this" {
  count = var.enable_waf ? 1 : 0

  name                              = var.waf_policy_name != "" ? var.waf_policy_name : "${replace(var.profile_name, "-", "")}waf"
  resource_group_name               = var.resource_group_name
  sku_name                          = var.sku_name
  mode                              = var.waf_mode
  enabled                           = true
  custom_block_response_status_code = 403
  tags                              = var.tags

  dynamic "managed_rule" {
    for_each = var.waf_managed_rules

    content {
      type    = managed_rule.value.type
      version = managed_rule.value.version
      action  = managed_rule.value.action

      dynamic "exclusion" {
        for_each = managed_rule.value.exclusions

        content {
          match_variable = exclusion.value.match_variable
          operator       = exclusion.value.operator
          selector       = exclusion.value.selector
        }
      }

      dynamic "override" {
        for_each = managed_rule.value.overrides

        content {
          rule_group_name = override.value.rule_group_name

          dynamic "rule" {
            for_each = override.value.rules

            content {
              rule_id = rule.value.rule_id
              action  = rule.value.action
              enabled = rule.value.enabled
            }
          }
        }
      }
    }
  }

  dynamic "custom_rule" {
    for_each = var.waf_custom_rules

    content {
      name     = custom_rule.value.name
      action   = custom_rule.value.action
      type     = custom_rule.value.type
      priority = custom_rule.value.priority
      enabled  = custom_rule.value.enabled

      rate_limit_duration_in_minutes = custom_rule.value.type == "RateLimitRule" ? custom_rule.value.rate_limit_duration_in_minutes : null
      rate_limit_threshold           = custom_rule.value.type == "RateLimitRule" ? custom_rule.value.rate_limit_threshold : null

      dynamic "match_condition" {
        for_each = custom_rule.value.match_conditions

        content {
          match_variable     = match_condition.value.match_variable
          operator           = match_condition.value.operator
          match_values       = match_condition.value.match_values
          negation_condition = match_condition.value.negation_condition
          selector           = match_condition.value.selector
          transforms         = match_condition.value.transforms
        }
      }
    }
  }
}

###############################################################################
# Security Policy - Links WAF to Endpoints
###############################################################################
resource "azurerm_cdn_frontdoor_security_policy" "this" {
  count = var.enable_waf ? 1 : 0

  name                     = "${var.profile_name}-security-policy"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.this[0].id

      association {
        patterns_to_match = ["/*"]

        dynamic "domain" {
          for_each = azurerm_cdn_frontdoor_endpoint.this

          content {
            cdn_frontdoor_domain_id = domain.value.id
          }
        }
      }
    }
  }
}
