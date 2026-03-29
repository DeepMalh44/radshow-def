variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
}

variable "vnet_name" {
  description = "Name of the virtual network"
  type        = string
}

variable "address_space" {
  description = "Address space for the virtual network"
  type        = list(string)
}

variable "subnets" {
  description = "Map of subnet configurations"
  type = map(object({
    address_prefixes = list(string)
    delegation = optional(object({
      name    = string
      actions = list(string)
    }))
    is_sqlmi_subnet   = optional(bool, false)
    is_apim_subnet    = optional(bool, false)
    service_endpoints = optional(list(string), [])
  }))
}

variable "private_dns_zones" {
  description = "Map of private DNS zone key to zone name"
  type        = map(string)
  default     = {}
}

variable "enable_private_dns_zones" {
  description = "Whether to create private DNS zones"
  type        = bool
  default     = true
}

variable "secondary_vnet_id" {
  description = "Optional ID of secondary VNet to link to private DNS zones"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
