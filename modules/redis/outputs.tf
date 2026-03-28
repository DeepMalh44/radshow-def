output "id" {
  description = "The resource ID of the Redis Cache"
  value       = azurerm_redis_cache.this.id
}

output "name" {
  description = "The name of the Redis Cache"
  value       = azurerm_redis_cache.this.name
}

output "hostname" {
  description = "The hostname of the Redis Cache"
  value       = azurerm_redis_cache.this.hostname
}

output "ssl_port" {
  description = "The SSL port of the Redis Cache"
  value       = azurerm_redis_cache.this.ssl_port
}

output "primary_access_key" {
  description = "The primary access key for the Redis Cache"
  value       = azurerm_redis_cache.this.primary_access_key
  sensitive   = true
}

output "secondary_access_key" {
  description = "The secondary access key for the Redis Cache"
  value       = azurerm_redis_cache.this.secondary_access_key
  sensitive   = true
}

output "primary_connection_string" {
  description = "The primary connection string for the Redis Cache"
  value       = azurerm_redis_cache.this.primary_connection_string
  sensitive   = true
}

output "linked_server_id" {
  description = "The resource ID of the geo-replication linked server"
  value       = var.enable_geo_replication ? azurerm_redis_linked_server.this[0].id : null
}
