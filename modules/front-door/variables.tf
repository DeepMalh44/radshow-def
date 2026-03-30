variable "profile_name" {
  description = "Name of the Azure Front Door profile"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "sku_name" {
  description = "SKU name for the Front Door profile"
  type        = string
  default     = "Premium_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.sku_name)
    error_message = "SKU name must be Standard_AzureFrontDoor or Premium_AzureFrontDoor."
  }
}

variable "response_timeout_seconds" {
  description = "Response timeout in seconds for the Front Door profile"
  type        = number
  default     = 60
}

variable "origin_groups" {
  description = "Map of origin groups for active-passive routing"
  type = map(object({
    session_affinity_enabled = bool
    health_probe = object({
      interval_in_seconds = number
      path                = string
      protocol            = string
      request_type        = string
    })
    load_balancing = object({
      additional_latency_in_milliseconds = number
      sample_size                        = number
      successful_samples_required        = number
    })
  }))
}

variable "origins" {
  description = "Map of origins with priority for active-passive (primary=1, secondary=2)"
  type = map(object({
    origin_group_key               = string
    enabled                        = bool
    certificate_name_check_enabled = bool
    host_name                      = string
    origin_host_header             = string
    http_port                      = number
    https_port                     = number
    priority                       = number
    weight                         = number
    private_link = optional(object({
      location               = string
      private_link_target_id = string
      request_message        = string
      target_type            = string
    }))
  }))
}

variable "endpoints" {
  description = "Map of Front Door endpoints"
  type = map(object({
    enabled = bool
  }))
}

variable "routes" {
  description = "Map of routes linking endpoints to origin groups"
  type = map(object({
    endpoint_key           = string
    origin_group_key       = string
    origin_keys            = list(string)
    enabled                = bool
    forwarding_protocol    = string
    https_redirect_enabled = bool
    patterns_to_match      = list(string)
    supported_protocols    = list(string)
    link_to_default_domain = bool
    custom_domain_names    = optional(list(string), [])
    cache = optional(object({
      query_string_caching_behavior = string
      query_strings                 = optional(list(string), [])
      compression_enabled           = optional(bool, false)
      content_types_to_compress     = optional(list(string), [])
    }))
  }))
}

variable "custom_domains" {
  description = "Map of custom domains to attach to Front Door"
  type = map(object({
    host_name           = string
    certificate_type    = string
    minimum_tls_version = string
  }))
  default = {}
}

variable "enable_waf" {
  description = "Whether to create a WAF policy and attach it to endpoints"
  type        = bool
  default     = true
}

variable "waf_policy_name" {
  description = "Name of the WAF policy"
  type        = string
  default     = ""
}

variable "waf_mode" {
  description = "WAF mode: Detection or Prevention"
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "WAF mode must be Detection or Prevention."
  }
}

variable "waf_managed_rules" {
  description = "List of managed rule sets for the WAF policy"
  type = list(object({
    type    = string
    version = string
    action  = string
    exclusions = optional(list(object({
      match_variable = string
      operator       = string
      selector       = string
    })), [])
    overrides = optional(list(object({
      rule_group_name = string
      rules = optional(list(object({
        rule_id = string
        action  = string
        enabled = bool
      })), [])
    })), [])
  }))
  default = []
}

variable "waf_custom_rules" {
  description = "List of custom rules for the WAF policy"
  type = list(object({
    name                           = string
    action                         = string
    type                           = string
    priority                       = number
    enabled                        = optional(bool, true)
    rate_limit_duration_in_minutes = optional(number, 1)
    rate_limit_threshold           = optional(number, 10)
    match_conditions = list(object({
      match_variable     = string
      operator           = string
      match_values       = list(string)
      negation_condition = optional(bool, false)
      selector           = optional(string)
      transforms         = optional(list(string), [])
    }))
  }))
  default = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
