resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = each.value.address_prefixes
  service_endpoints    = each.value.service_endpoints

  dynamic "delegation" {
    for_each = each.value.delegation != null ? [each.value.delegation] : []
    content {
      name = delegation.value.name
      service_delegation {
        name    = delegation.value.name
        actions = delegation.value.actions
      }
    }
  }
}

resource "azurerm_network_security_group" "this" {
  for_each = var.subnets

  name                = "nsg-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = var.subnets

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

#--------------------------------------------------------------
# APIM NSG Rules for VNet Internal Mode
# Port 3443: Management plane (ApiManagement service tag)
# Port 6390: Azure Load Balancer health probe
#--------------------------------------------------------------
locals {
  apim_subnets = { for k, v in var.subnets : k => v if v.is_apim_subnet }
}

resource "azurerm_network_security_rule" "apim_management_3443" {
  for_each = local.apim_subnets

  name                        = "Allow_APIM_Management_3443"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3443"
  source_address_prefix       = "ApiManagement"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "apim_loadbalancer_6390" {
  for_each = local.apim_subnets

  name                        = "Allow_APIM_LoadBalancer_6390"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "6390"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

#--------------------------------------------------------------
# APIM NSG Rules for HTTPS (443) - Front Door & Internet access
# Required for External VNet mode: AFD → APIM gateway traffic
#--------------------------------------------------------------
resource "azurerm_network_security_rule" "apim_frontdoor_443" {
  for_each = local.apim_subnets

  name                        = "Allow_FrontDoor_HTTPS_443"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "AzureFrontDoor.Backend"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "apim_internet_443" {
  for_each = local.apim_subnets

  name                        = "Allow_Internet_HTTPS_443"
  priority                    = 105
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

locals {
  sqlmi_subnets           = { for k, v in var.subnets : k => v if v.is_sqlmi_subnet }
  sqlmi_public_ep_subnets = var.enable_sqlmi_public_endpoint ? local.sqlmi_subnets : {}
}

#--------------------------------------------------------------
# Application Gateway NSG Rules
# GatewayManager (v2 control plane), LoadBalancer, FrontDoor, Deny
#--------------------------------------------------------------
locals {
  appgw_subnets = { for k, v in var.subnets : k => v if v.is_appgw_subnet }
}

resource "azurerm_network_security_rule" "appgw_gateway_manager" {
  for_each = local.appgw_subnets

  name                        = "Allow_GatewayManager"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "appgw_load_balancer" {
  for_each = local.appgw_subnets

  name                        = "Allow_AzureLoadBalancer"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "appgw_frontdoor_443" {
  for_each = local.appgw_subnets

  name                        = "Allow_FrontDoor_HTTPS_443"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "AzureFrontDoor.Backend"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "appgw_frontdoor_80" {
  for_each = local.appgw_subnets

  name                        = "Allow_FrontDoor_HTTP_80"
  priority                    = 121
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "AzureFrontDoor.Backend"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "appgw_deny_internet" {
  for_each = local.appgw_subnets

  name                        = "Deny_Internet_Inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_network_security_rule" "sqlmi_public_endpoint_3342" {
  for_each = local.sqlmi_public_ep_subnets

  name                        = "Allow_SqlMI_Public_3342"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3342"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this[each.key].name
}

resource "azurerm_route_table" "sqlmi" {
  for_each = local.sqlmi_subnets

  name                          = "rt-${each.key}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  bgp_route_propagation_enabled = true
  tags                          = var.tags
}

resource "azurerm_subnet_route_table_association" "sqlmi" {
  for_each = local.sqlmi_subnets

  subnet_id      = azurerm_subnet.this[each.key].id
  route_table_id = azurerm_route_table.sqlmi[each.key].id
}

resource "azurerm_private_dns_zone" "this" {
  for_each = var.enable_private_dns_zones ? var.private_dns_zones : {}

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = var.enable_private_dns_zones ? var.private_dns_zones : {}

  name                  = "link-${each.key}-${var.vnet_name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "secondary" {
  for_each = var.enable_private_dns_zones && var.secondary_vnet_id != "" ? var.private_dns_zones : {}

  name                  = "link-${each.key}-secondary"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = var.secondary_vnet_id
  registration_enabled  = false
  tags                  = var.tags
}
