variable "failover_group_name" {
  description = "Name of the failover group"
  type        = string
}

variable "location" {
  description = "Azure region of the primary SQL MI"
  type        = string
}

variable "primary_instance_id" {
  description = "Resource ID of the primary SQL Managed Instance"
  type        = string
}

variable "secondary_instance_id" {
  description = "Resource ID of the secondary SQL Managed Instance"
  type        = string
}

variable "failover_grace_minutes" {
  description = "Grace period in minutes before automatic failover (minimum 60)"
  type        = number
  default     = 60
}

variable "primary_instance_fqdn" {
  description = "FQDN of the primary SQL MI (used to derive the FOG listener endpoint)"
  type        = string
}
