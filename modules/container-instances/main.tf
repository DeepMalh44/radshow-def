resource "azurerm_container_group" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = var.os_type
  restart_policy      = var.restart_policy
  ip_address_type     = var.ip_address_type
  dns_name_label      = var.dns_name_label
  subnet_ids          = length(var.subnet_ids) > 0 ? var.subnet_ids : null

  dynamic "container" {
    for_each = var.containers
    content {
      name   = container.value.name
      image  = container.value.image
      cpu    = container.value.cpu
      memory = container.value.memory

      dynamic "ports" {
        for_each = container.value.ports
        content {
          port     = ports.value.port
          protocol = ports.value.protocol
        }
      }

      environment_variables        = length(container.value.environment_variables) > 0 ? container.value.environment_variables : null
      secure_environment_variables = length(container.value.secure_environment_variables) > 0 ? container.value.secure_environment_variables : null
      commands                     = length(container.value.commands) > 0 ? container.value.commands : null
    }
  }

  dynamic "image_registry_credential" {
    for_each = var.image_registry_credential != null ? [var.image_registry_credential] : []
    content {
      server   = image_registry_credential.value.server
      username = image_registry_credential.value.username
      password = image_registry_credential.value.password
    }
  }

  identity {
    type         = var.identity_type
    identity_ids = var.user_assigned_identity_ids
  }

  tags = var.tags
}
