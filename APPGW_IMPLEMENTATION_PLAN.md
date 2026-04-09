# Application Gateway Implementation Plan

> **Status:** PENDING APPROVAL  
> **Created:** 2026-04-08  
> **Decisions:** Option B (public AppGW + NSG lockdown) all environments, self-signed KV cert, /24 subnets

---

## Architecture Summary

```
Internet → Front Door (Premium, WAF, managed TLS)
              │
              │  Public origin (NSG-locked to AzureFrontDoor.Backend + X-Azure-FDID validation)
              ▼
         Application Gateway (WAF_v2, per region)
              │  Public IP exists but NSG blocks direct internet
              │  Self-signed cert from Key Vault on HTTPS listener
              │  URL Path Map routing:
              │
              ├── /api/*    → Backend Pool: APIM private IP (Internal mode)
              └── /* (default) → Backend Pool: Storage SPA ($web)
```

**Key design choices:**
- **Option B everywhere** — No Private Link. App GW has public IP, locked via NSG to `AzureFrontDoor.Backend` service tag + WAF custom rule validating `X-Azure-FDID` header matches our Front Door profile ID
- **Self-signed certificate** in Key Vault for App GW HTTPS listener (Front Door handles public TLS)
- **/24 subnets** (`10.x.10.0/24`) — plenty of room in /16 address spaces, consistent with existing subnet sizing

---

## Environments

| Env | Primary Region | Secondary Region | App GW Count | FD → AppGW |
|-----|---------------|-----------------|-------------|------------|
| DEV01 | swedencentral | *(none, DR off)* | 1 | Public + NSG lockdown |
| STG01 | centralindia | southindia | 2 | Public + NSG lockdown |
| PRD01 | southcentralus | northcentralus | 2 | Public + NSG lockdown |

---

## Phase 1: New Terraform Module — `modules/application-gateway/`

### 1.1 `modules/application-gateway/variables.tf`

```hcl
variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "subnet_id" { type = string }
variable "tags" { type = map(string), default = {} }

# SKU
variable "sku_name" { type = string, default = "WAF_v2" }
variable "sku_tier" { type = string, default = "WAF_v2" }
variable "min_capacity" { type = number, default = 1 }
variable "max_capacity" { type = number, default = 2 }

# WAF
variable "enable_waf" { type = bool, default = true }
variable "waf_mode" { type = string, default = "Prevention" }

# Front Door ID for X-Azure-FDID validation (WAF custom rule)
variable "front_door_id" { type = string }

# TLS certificate
variable "key_vault_secret_id" {
  type        = string
  description = "Key Vault versioned secret ID for the self-signed TLS cert"
}
variable "key_vault_id" {
  type        = string
  description = "Key Vault resource ID (for access policy)"
}

# Backend targets
variable "apim_fqdn" {
  type        = string
  description = "APIM gateway FQDN (e.g. apim-radshow-stg01-cin.azure-api.net)"
}
variable "storage_web_fqdn" {
  type        = string
  description = "Storage static website FQDN (e.g. stradshowstg01cin.z29.web.core.windows.net)"
}

# Listener hostname (optional — if empty, uses wildcard)
variable "listener_host_name" {
  type    = string
  default = null
}
```

### 1.2 `modules/application-gateway/main.tf`

Resources to create:

1. **`azurerm_public_ip`** — Standard SKU, static allocation (required for WAF_v2 + NSG control plane)
2. **`azurerm_user_assigned_identity`** — For Key Vault certificate access
3. **`azurerm_key_vault_access_policy`** — Grant identity GET on secrets/certificates
4. **`azurerm_application_gateway`** with:
   - **Frontend IP:** Public IP only
   - **Gateway IP configuration:** Linked to `snet-appgw` subnet
   - **SSL certificate:** Referenced from Key Vault via `key_vault_secret_id`
   - **Backend address pools (2):**
     - `bp-apim` → `var.apim_fqdn`
     - `bp-spa` → `var.storage_web_fqdn`
   - **Backend HTTP settings (2):**
     - `bhs-apim` — HTTPS:443, host_name override = `var.apim_fqdn`, probe = `probe-apim`
     - `bhs-spa` — HTTPS:443, host_name override = `var.storage_web_fqdn`, probe = `probe-spa`
   - **Health probes (2):**
     - `probe-apim` — HTTPS, path `/api/healthz`, host = `var.apim_fqdn`, interval 30s
     - `probe-spa` — HTTPS, path `/index.html`, host = `var.storage_web_fqdn`
   - **HTTP listener:** HTTPS on port 443, SSL cert from KV
   - **URL path map:**
     - `/api/*` → `bp-apim` + `bhs-apim`
     - default → `bp-spa` + `bhs-spa`
   - **Request routing rule:** PathBasedRouting, priority 1
   - **Autoscale:** `min_capacity` to `max_capacity`
   - **WAF configuration:** OWASP 3.2, Prevention mode (conditional on `var.enable_waf`)
   - **WAF policy** (separate `azurerm_web_application_firewall_policy` resource):
     - Managed rule set: OWASP 3.2
     - **Custom rule: Validate X-Azure-FDID header**
       ```
       priority 1, match condition:
         match_variable = "RequestHeaders"
         selector = "X-Azure-FDID"
         operator = "Equal"
         negation = true
         match_values = [var.front_door_id]
       action = "Block"
       ```
       This blocks any request that does NOT have the correct Front Door ID header.

### 1.3 `modules/application-gateway/outputs.tf`

```hcl
output "public_ip_address" { value = azurerm_public_ip.this.ip_address }
output "application_gateway_id" { value = azurerm_application_gateway.this.id }
output "identity_principal_id" { value = azurerm_user_assigned_identity.this.principal_id }
output "name" { value = azurerm_application_gateway.this.name }
```

---

## Phase 2: Modify `modules/networking/`

### 2.1 `variables.tf` — Add `is_appgw_subnet` to subnet type

Add `is_appgw_subnet = optional(bool, false)` to the subnet object type, alongside existing `is_apim_subnet` and `is_sqlmi_subnet`.

### 2.2 `main.tf` — Add App Gateway NSG rules

```hcl
locals {
  appgw_subnets = { for k, v in var.subnets : k => v if v.is_appgw_subnet }
}

# Required: GatewayManager for v2 SKU control plane
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

# Required: Azure Load Balancer health probes
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

# Allow Front Door backend traffic on 443
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

# Deny all other inbound internet traffic
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
```

### 2.3 `main.tf` — Remove APIM internet-facing NSG rules (deferred)

**After** App Gateway is verified working and Front Door routes are switched:
- Remove `azurerm_network_security_rule.apim_frontdoor_443` (Allow_FrontDoor_HTTPS_443)
- Remove `azurerm_network_security_rule.apim_internet_443` (Allow_Internet_HTTPS_443)

APIM will only receive traffic from App GW within the VNet. These removals happen in Phase 5 (cleanup).

---

## Phase 3: Modify `modules/front-door/`

No module code changes needed — the module is already generic. All changes happen in Terragrunt inputs.

---

## Phase 4: Terragrunt Changes (radshow-lic)

### 4.1 New file: `_envcommon/application-gateway.hcl`

Common Terragrunt config pointing to `modules/application-gateway`.

### 4.2 All environments: Add `snet-appgw` to networking configs

**In each `networking/terragrunt.hcl` and `networking-secondary/terragrunt.hcl`:**

```hcl
"snet-appgw" = {
  address_prefixes = ["10.x.10.0/24"]   # 10.1.10.0 primary, 10.2.10.0 secondary
  is_appgw_subnet  = true
}
```

No delegation needed — App Gateway v2 uses standard subnet association, not delegation.

Subnet map per VNet:

| Subnet | CIDR | Notes |
|--------|------|-------|
| snet-apim | 10.x.1.0/24 | Existing |
| snet-app | 10.x.2.0/24 | Existing |
| snet-func | 10.x.3.0/24 | Existing |
| snet-aca | 10.x.4.0/23 | Existing |
| snet-pe | 10.x.6.0/24 | Existing |
| snet-aci | 10.x.7.0/24 | Existing |
| snet-sqlmi | 10.x.8.0/24 | Existing |
| snet-redis | 10.x.9.0/24 | Existing |
| **snet-appgw** | **10.x.10.0/24** | **NEW** |

### 4.3 New Terragrunt configs per environment

**DEV01:**
- `DEV01/application-gateway/terragrunt.hcl`

**STG01:**
- `STG01/application-gateway/terragrunt.hcl` (centralindia)
- `STG01/application-gateway-secondary/terragrunt.hcl` (southindia)

**PRD01:**
- `PRD01/application-gateway/terragrunt.hcl` (southcentralus)
- `PRD01/application-gateway-secondary/terragrunt.hcl` (northcentralus)

Each depends on: `resource-group`, `networking`, `apim`, `storage`, `key-vault`

### 4.4 Self-signed certificate in Key Vault

**Option A (simplest):** Generate self-signed cert via `az keyvault certificate create` with a policy, then reference the secret ID in Terragrunt.

**Option B (Terraform-managed):** Use `azurerm_key_vault_certificate` resource in the `key-vault` module with a self-signed certificate policy.

**Recommendation:** Option B (Terraform-managed) — stays in IaC, auto-renews.

Add to `modules/key-vault/main.tf`:

```hcl
resource "azurerm_key_vault_certificate" "appgw_ssl" {
  count    = var.generate_appgw_cert ? 1 : 0
  name     = "appgw-ssl-cert"
  key_vault_id = azurerm_key_vault.this.id

  certificate_policy {
    issuer_parameters { name = "Self" }
    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }
    secret_properties { content_type = "application/x-pkcs12" }
    x509_certificate_properties {
      key_usage          = ["digitalSignature", "keyEncipherment"]
      subject            = "CN=appgw-${var.name_prefix}"
      validity_in_months = 12
      subject_alternative_names {
        dns_names = ["*.azurefd.net"]  # Matches FD origin host header
      }
    }
    lifetime_action {
      action { action_type = "AutoRenew" }
      trigger { days_before_expiry = 30 }
    }
  }
}

output "appgw_cert_secret_id" {
  value = try(azurerm_key_vault_certificate.appgw_ssl[0].secret_id, null)
}
```

### 4.5 Modify Front Door Terragrunt inputs

**Replace** the current 3 origin groups / 6 origins / 3 routes pattern with:

```hcl
origin_groups = {
  "og-appgw" = {
    session_affinity_enabled = false
    restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 10
    health_probe = {
      interval_in_seconds = 30
      path                = "/api/healthz"    # Validates full path: AppGW → APIM → Function
      protocol            = "Https"
      request_type        = "GET"
    }
    load_balancing = {
      additional_latency_in_milliseconds = 0
      sample_size                        = 4
      successful_samples_required        = 2
    }
  }
}

origins = {
  "appgw-primary" = {
    origin_group_key               = "og-appgw"
    enabled                        = true
    certificate_name_check_enabled = false  # Self-signed cert
    host_name                      = dependency.application_gateway.outputs.public_ip_address
    origin_host_header             = dependency.application_gateway.outputs.public_ip_address
    http_port                      = 80
    https_port                     = 443
    priority                       = 1
    weight                         = 1000
  }
  "appgw-secondary" = {
    origin_group_key               = "og-appgw"
    enabled                        = true
    certificate_name_check_enabled = false
    host_name                      = dependency.application_gateway_secondary.outputs.public_ip_address
    origin_host_header             = dependency.application_gateway_secondary.outputs.public_ip_address
    http_port                      = 80
    https_port                     = 443
    priority                       = 2
    weight                         = 1000
  }
}

routes = {
  "route-all" = {
    endpoint_key           = "ep-spa"
    origin_group_key       = "og-appgw"
    origin_keys            = ["appgw-primary", "appgw-secondary"]
    enabled                = true
    forwarding_protocol    = "HttpsOnly"
    https_redirect_enabled = true
    patterns_to_match      = ["/*"]
    supported_protocols    = ["Http", "Https"]
    link_to_default_domain = true
    # No cache — App GW handles path routing; SPA caching can be added later
  }
}
```

For DEV01 (single region), only `appgw-primary` origin (no secondary).

---

## Phase 5: Cleanup (after App GW verified working)

1. **Remove APIM NSG rules** — delete `apim_frontdoor_443` and `apim_internet_443` from `modules/networking/main.tf`
2. **Update `env.hcl`** — no changes needed (feature flags unchanged)

---

## Phase 6: Runbook / Script Updates

### 6.1 `runbooks/00-setup-environment.ps1`

Add to `$Config`:
```powershell
AppGwPrimaryName         = "appgw-radshow-{env}-{primary_short}"
AppGwSecondaryName       = "appgw-radshow-{env}-{secondary_short}"
AppGwPrimaryRG           = $Config.PrimaryResourceGroup
AppGwSecondaryRG         = $Config.SecondaryResourceGroup
```

### 6.2 `runbooks/01-check-health.ps1`

Add new health check section:
```powershell
# ── N. Application Gateway ──
Write-Host "[CHECK] Application Gateway" -ForegroundColor Yellow
foreach ($appgw in @(
    @{ Name = $Config.AppGwPrimaryName; RG = $Config.AppGwPrimaryRG; Label = "Primary" }
    @{ Name = $Config.AppGwSecondaryName; RG = $Config.AppGwSecondaryRG; Label = "Secondary" }
)) {
    $gw = Get-AzApplicationGateway -Name $appgw.Name -ResourceGroupName $appgw.RG
    # Check operational state + backend health
    $backendHealth = Get-AzApplicationGatewayBackendHealth -Name $appgw.Name -ResourceGroupName $appgw.RG
    # Report per-pool health
}
```

### 6.3 `runbooks/02-planned-failover.ps1`, `03-unplanned-failover.ps1`, `04-planned-failback.ps1`

**No script logic changes needed.** The existing Step 3 (FD origin priority swap) iterates ALL origin groups and swaps priorities based on hostname region matching. With 1 origin group (`og-appgw`) containing 2 origins with region-specific IPs, the same loop works.

However: origin hostnames will be IP addresses, not FQDNs with region short names. The matching logic `$origin.HostName -match $Config.SecondaryRegionShort` **will NOT match** an IP address.

**Fix required:** Update the matching logic to use origin **name** instead of hostname:
```powershell
# BEFORE:
$isSecondary = $origin.HostName -match $Config.SecondaryRegionShort

# AFTER:
$isSecondary = $origin.Name -match "secondary"
```

This change applies to:
- `02-planned-failover.ps1` (Step 3)
- `03-unplanned-failover.ps1` (Step 2 — same FD swap logic)
- `04-planned-failback.ps1` (Step 3 — reverse swap)

### 6.4 `runbooks/05-validate-failover.ps1`

Same hostname matching fix as above, plus add App GW backend health validation section.

### 6.5 Function App env var update

Current `FRONT_DOOR_ORIGIN_GROUP_NAME` on func apps is `"og-api,og-spa"`. Update to `"og-appgw"`.

---

## Deployment Order

Execute in this order per environment:

```
Step 1: modules/key-vault           → Add self-signed cert resource + output
Step 2: modules/networking          → Add is_appgw_subnet + NSG rules
Step 3: modules/application-gateway → New module (entire directory)
Step 4: Terragrunt networking       → Add snet-appgw subnet to all VNets
Step 5: Terragrunt key-vault        → Apply to generate cert (enable generate_appgw_cert)
Step 6: Terragrunt application-gw   → Deploy App GW per region
Step 7: Terragrunt front-door       → Switch to og-appgw + route-all
Step 8: Verify all traffic flows through App GW
Step 9: modules/networking          → Remove APIM internet NSG rules (cleanup)
Step 10: Terragrunt networking      → Apply cleanup
Step 11: Runbooks                   → Update scripts
Step 12: Func app env vars          → Update FRONT_DOOR_ORIGIN_GROUP_NAME
```

**Recommended environment order:** DEV01 → STG01 → PRD01

---

## Files to Create/Modify Summary

### New files (radshow-def):
| File | Description |
|------|-------------|
| `modules/application-gateway/main.tf` | App GW + WAF policy + public IP + identity |
| `modules/application-gateway/variables.tf` | Input variables |
| `modules/application-gateway/outputs.tf` | Outputs (IP, ID, name) |

### Modified files (radshow-def):
| File | Change |
|------|--------|
| `modules/networking/main.tf` | Add `appgw_subnets` local + 4 NSG rules |
| `modules/networking/variables.tf` | Add `is_appgw_subnet` to subnet type |
| `modules/key-vault/main.tf` | Add self-signed cert resource |
| `modules/key-vault/variables.tf` | Add `generate_appgw_cert`, `name_prefix` vars |
| `modules/key-vault/outputs.tf` | Add `appgw_cert_secret_id` output |
| `runbooks/00-setup-environment.ps1` | Add AppGw config entries |
| `runbooks/01-check-health.ps1` | Add App GW health check section |
| `runbooks/02-planned-failover.ps1` | Fix origin matching to use name |
| `runbooks/03-unplanned-failover.ps1` | Fix origin matching to use name |
| `runbooks/04-planned-failback.ps1` | Fix origin matching to use name |
| `runbooks/05-validate-failover.ps1` | Fix origin matching + add App GW validation |

### New files (radshow-lic):
| File | Description |
|------|-------------|
| `_envcommon/application-gateway.hcl` | Common App GW Terragrunt config |
| `DEV01/application-gateway/terragrunt.hcl` | DEV01 App GW |
| `STG01/application-gateway/terragrunt.hcl` | STG01 primary App GW |
| `STG01/application-gateway-secondary/terragrunt.hcl` | STG01 secondary App GW |
| `PRD01/application-gateway/terragrunt.hcl` | PRD01 primary App GW |
| `PRD01/application-gateway-secondary/terragrunt.hcl` | PRD01 secondary App GW |

### Modified files (radshow-lic):
| File | Change |
|------|--------|
| `DEV01/networking/terragrunt.hcl` | Add snet-appgw |
| `STG01/networking/terragrunt.hcl` | Add snet-appgw |
| `STG01/networking-secondary/terragrunt.hcl` | Add snet-appgw |
| `PRD01/networking/terragrunt.hcl` | Add snet-appgw |
| `PRD01/networking-secondary/terragrunt.hcl` | Add snet-appgw |
| `DEV01/key-vault/terragrunt.hcl` | Add generate_appgw_cert = true |
| `STG01/key-vault/terragrunt.hcl` | Add generate_appgw_cert = true |
| `STG01/key-vault-secondary/terragrunt.hcl` | Add generate_appgw_cert = true |
| `PRD01/key-vault/terragrunt.hcl` | Add generate_appgw_cert = true |
| `PRD01/key-vault-secondary/terragrunt.hcl` | Add generate_appgw_cert = true |
| `DEV01/front-door/terragrunt.hcl` | Rewrite to og-appgw pattern |
| `STG01/front-door/terragrunt.hcl` | Rewrite to og-appgw pattern |
| `PRD01/front-door/terragrunt.hcl` | Rewrite to og-appgw pattern |

---

## Risk Mitigation

1. **Zero-downtime migration:** Deploy App GW first, verify health probes pass, THEN switch Front Door. Old origins stay until verified.
2. **Rollback:** If App GW has issues, revert Front Door Terragrunt inputs to old 3-origin-group pattern. App GW sits idle but harmless.
3. **Self-signed cert renewal:** `azurerm_key_vault_certificate` with `lifetime_action` auto-renews 30 days before expiry.
4. **APIM NSG cleanup last:** Keep FD→APIM NSG rules until App GW path is fully verified, then remove in Phase 5.
