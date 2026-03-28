variable "name" {
  type        = string
  description = "Name of the private endpoint."
}

variable "location" {
  type        = string
  description = "Azure region for the private endpoint."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group."
}

variable "subnet_id" {
  type        = string
  description = "ID of the subnet to place the private endpoint in."
}

variable "private_connection_resource_id" {
  type        = string
  description = "Resource ID of the target service to connect to."
}

variable "subresource_names" {
  type        = list(string)
  description = "List of subresource names for the private endpoint (e.g. [\"blob\"], [\"vault\"], [\"sqlServer\"])."
}

variable "is_manual_connection" {
  type        = bool
  default     = false
  description = "Whether the private endpoint connection requires manual approval."
}

variable "request_message" {
  type        = string
  default     = null
  description = "A message passed to the owner of the remote resource for manual connections."
}

variable "private_dns_zone_ids" {
  type        = list(string)
  default     = []
  description = "List of private DNS zone IDs to associate with the private endpoint."
}

variable "private_dns_zone_group_name" {
  type        = string
  default     = "default"
  description = "Name of the private DNS zone group."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to the private endpoint."
}
