resource "azurerm_container_app_environment" "this" {
  name                           = var.environment_name
  location                       = var.location
  resource_group_name            = var.resource_group_name
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  infrastructure_subnet_id       = var.infrastructure_subnet_id
  internal_load_balancer_enabled = var.internal_load_balancer_enabled
  zone_redundancy_enabled        = var.zone_redundancy_enabled

  tags = var.tags
}

#--------------------------------------------------------------
# User-Assigned Managed Identity for ACR pull
# Created BEFORE the Container App so AcrPull is in place when
# the first revision tries to pull the image. Avoids the
# chicken-and-egg where SystemAssigned identity only exists
# after the CA is created (too late for the initial image pull).
#--------------------------------------------------------------
resource "azurerm_user_assigned_identity" "acr_pull" {
  count = var.acr_id != null ? 1 : 0

  name                = "${var.environment_name}-acr-pull-mi"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  count = var.acr_id != null ? 1 : 0

  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.acr_pull[0].principal_id
}

resource "azurerm_container_app" "this" {
  for_each = var.container_apps

  name                         = each.value.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = each.value.revision_mode

  # Ensure AcrPull is assigned before the CA tries to pull
  depends_on = [azurerm_role_assignment.acr_pull]

  dynamic "ingress" {
    for_each = each.value.ingress != null ? [each.value.ingress] : []
    content {
      external_enabled = ingress.value.external_enabled
      target_port      = ingress.value.target_port
      transport        = ingress.value.transport

      traffic_weight {
        percentage      = 100
        latest_revision = true
      }
    }
  }

  template {
    dynamic "container" {
      for_each = each.value.template.containers
      content {
        name   = container.value.name
        image  = container.value.image
        cpu    = container.value.cpu
        memory = container.value.memory

        dynamic "env" {
          for_each = container.value.env
          content {
            name        = env.value.name
            value       = env.value.secret_name == null ? env.value.value : null
            secret_name = env.value.secret_name
          }
        }
      }
    }

    min_replicas    = each.value.template.min_replicas
    max_replicas    = each.value.template.max_replicas
    revision_suffix = each.value.template.revision_suffix
  }

  dynamic "registry" {
    for_each = each.value.registry != null ? [each.value.registry] : []
    content {
      server   = registry.value.server
      identity = var.acr_id != null ? azurerm_user_assigned_identity.acr_pull[0].id : registry.value.identity
    }
  }

  dynamic "identity" {
    for_each = each.value.identity != null ? [each.value.identity] : []
    content {
      type = var.acr_id != null && identity.value.type == "SystemAssigned" ? "SystemAssigned, UserAssigned" : identity.value.type
      identity_ids = var.acr_id != null ? concat(
        coalesce(identity.value.identity_ids, []),
        [azurerm_user_assigned_identity.acr_pull[0].id]
      ) : identity.value.identity_ids
    }
  }

  dynamic "secret" {
    for_each = each.value.secrets
    content {
      name  = secret.value.name
      value = secret.value.value
    }
  }

  tags = var.tags
}

#--------------------------------------------------------------
# Private DNS Zone for Internal Container App Environment
# When the CAE uses an internal load balancer, APIM (on VNet)
# needs a private DNS zone to resolve the CAE's custom domain
# to its static internal IP.
#--------------------------------------------------------------
resource "azurerm_private_dns_zone" "cae" {
  count = var.internal_load_balancer_enabled ? 1 : 0

  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "cae_wildcard" {
  count = var.internal_load_balancer_enabled ? 1 : 0

  name                = "*"
  zone_name           = azurerm_private_dns_zone.cae[0].name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

resource "azurerm_private_dns_a_record" "cae_apex" {
  count = var.internal_load_balancer_enabled ? 1 : 0

  name                = "@"
  zone_name           = azurerm_private_dns_zone.cae[0].name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "cae" {
  for_each = var.internal_load_balancer_enabled ? toset(var.vnet_ids_for_dns_link) : toset([])

  name                  = "link-${md5(each.value)}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cae[0].name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = var.tags
}
