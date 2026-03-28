variable "peering_name_1_to_2" {
  description = "Name of the peering from VNet 1 to VNet 2"
  type        = string
}

variable "peering_name_2_to_1" {
  description = "Name of the peering from VNet 2 to VNet 1"
  type        = string
}

variable "vnet_1_id" {
  description = "Resource ID of VNet 1"
  type        = string
}

variable "vnet_1_resource_group_name" {
  description = "Resource group name containing VNet 1"
  type        = string
}

variable "vnet_1_name" {
  description = "Name of VNet 1"
  type        = string
}

variable "vnet_2_id" {
  description = "Resource ID of VNet 2"
  type        = string
}

variable "vnet_2_resource_group_name" {
  description = "Resource group name containing VNet 2"
  type        = string
}

variable "vnet_2_name" {
  description = "Name of VNet 2"
  type        = string
}

variable "allow_virtual_network_access" {
  description = "Allow access between the two virtual networks"
  type        = bool
  default     = true
}

variable "allow_forwarded_traffic" {
  description = "Allow forwarded traffic between the two virtual networks"
  type        = bool
  default     = true
}

variable "allow_gateway_transit_1_to_2" {
  description = "Allow gateway transit from VNet 1 to VNet 2"
  type        = bool
  default     = false
}

variable "use_remote_gateways_1_to_2" {
  description = "Use remote gateways for the peering from VNet 1 to VNet 2"
  type        = bool
  default     = false
}

variable "allow_gateway_transit_2_to_1" {
  description = "Allow gateway transit from VNet 2 to VNet 1"
  type        = bool
  default     = false
}

variable "use_remote_gateways_2_to_1" {
  description = "Use remote gateways for the peering from VNet 2 to VNet 1"
  type        = bool
  default     = false
}
