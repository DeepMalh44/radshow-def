output "peering_1_to_2_id" {
  description = "Resource ID of the peering from VNet 1 to VNet 2"
  value       = azurerm_virtual_network_peering.vnet_1_to_2.id
}

output "peering_2_to_1_id" {
  description = "Resource ID of the peering from VNet 2 to VNet 1"
  value       = azurerm_virtual_network_peering.vnet_2_to_1.id
}
