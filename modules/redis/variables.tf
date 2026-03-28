variable "name" {
  description = "Name of the Azure Redis Cache instance"
  type        = string
}

variable "location" {
  description = "Azure region for the Redis Cache"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "capacity" {
  description = "The size of the Redis cache (0-6 for Basic/Standard, 1-5 for Premium)"
  type        = number
  default     = 1
}

variable "family" {
  description = "The SKU family/pricing group (C for Basic/Standard, P for Premium)"
  type        = string
  default     = "P"
}

variable "sku_name" {
  description = "The SKU of Redis to use (Basic, Standard, Premium)"
  type        = string
  default     = "Premium"
}

variable "enable_non_ssl_port" {
  description = "Enable the non-SSL port (6379). Not recommended for production."
  type        = bool
  default     = false
}

variable "minimum_tls_version" {
  description = "The minimum TLS version"
  type        = string
  default     = "1.2"
}

variable "shard_count" {
  description = "Number of shards for Redis cluster (Premium only)"
  type        = number
  default     = 0
}

variable "replicas_per_master" {
  description = "Number of replicas per master node"
  type        = number
  default     = 1
}

variable "zones" {
  description = "Availability zones for the Redis Cache"
  type        = list(string)
  default     = []
}

variable "subnet_id" {
  description = "The ID of the subnet for VNet injection (Premium only)"
  type        = string
  default     = null
}

variable "redis_configuration" {
  description = "Redis configuration settings"
  type = object({
    maxmemory_policy                = optional(string, "volatile-lru")
    maxmemory_reserved              = optional(number)
    maxfragmentationmemory_reserved = optional(number)
    rdb_backup_enabled              = optional(bool)
    rdb_backup_frequency            = optional(number)
    rdb_storage_connection_string   = optional(string)
  })
  default = {}
}

variable "enable_geo_replication" {
  description = "Enable geo-replication by linking to a secondary cache"
  type        = bool
  default     = false
}

variable "linked_cache_id" {
  description = "Resource ID of the secondary Redis Cache for geo-replication"
  type        = string
  default     = ""
}

variable "linked_cache_location" {
  description = "Location of the linked (secondary) Redis Cache"
  type        = string
  default     = ""
}

variable "private_static_ip_address" {
  description = "Static IP address within the subnet for VNet-injected cache"
  type        = string
  default     = null
}

variable "patch_schedules" {
  description = "List of patch schedule windows"
  type = list(object({
    day_of_week        = string
    start_hour_utc     = number
    maintenance_window = optional(string, "PT5H")
  }))
  default = []
}

variable "enable_diagnostics" {
  description = "Enable diagnostic settings for the Redis Cache"
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace for diagnostics"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
