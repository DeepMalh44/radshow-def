# RAD Showcase — Handover Guide

## Repository Overview

| Repo | Purpose | Key Tech |
|------|---------|----------|
| **radshow-def** | Terraform modules (reusable infrastructure definitions) | Terraform, azurerm/azapi providers |
| **radshow-lic** | Terragrunt live infrastructure config (environments + OIDC setup) | Terragrunt v1.0+, Terraform v1.5+ |
| **radshow-api** | .NET 8 Isolated Azure Functions API (Docker container) | C#, Docker, Azure Functions |
| **radshow-spa** | Vue.js SPA (deployed to Azure Blob Storage `$web`) | Vue 3, TypeScript |
| **radshow-db** | SQL MI database migrations (EF Core + sqlcmd) | .NET, SQL MI |
| **radshow-apim** | APIOps — APIM policies, APIs, named values | Azure APIM, APIOps Toolkit |

## Architecture

- **Active-Passive DR** across two Azure regions per environment
- **Azure Front Door** (Premium, SKU `Premium_AzureFrontDoor`) routes traffic via single endpoint `ep-spa`:
  - `route-all` → `/*` → `og-appgw` (Application Gateway origins — primary + secondary)
  - FD terminates TLS from clients, forwards to AppGW on **HTTP (port 80)** over Azure backbone
- **Application Gateway** (WAF_v2) per region performs URL path-based routing:
  - `/api/*` → APIM gateway backend pool
  - `/*` (default) → Storage static website backend pool
  - WAF with OWASP 3.2 rules + custom `X-Azure-FDID` validation + Host header exclusion (rule 920350)
- **WAF Policy** on Front Door (Prevention mode) with managed rule sets and custom rate-limiting rules
- **APIM** proxies all API calls to backend Function Apps (per-region) and routes `/products` to Container Apps (Products API)
- **Container Apps** run the Products API (`ca-product-api`) in internal (VNet-integrated) Container App Environments. Requires private DNS zones with wildcard + apex A records linked to both VNets.
- **SQL MI Failover Group** (60-minute grace period, automatic failover) replicates databases across regions; all compute (Function App, Container Apps) uses the FOG listener endpoint
- **Redis Cache** deployed independently per region (Premium P1)
- **Key Vault** per region — locked down (`public-network-access=disabled` / `default-action=Deny`). Both contain `active-region` secret indicating which region is primary.

### Environments

| Env | Primary Region | Secondary Region | Short Codes |
|-----|---------------|-----------------|-------------|
| DEV01 | swedencentral | germanywestcentral | swc / gwc |
| STG01 | centralindia | southindia | cin / sin |
| PRD01 | southcentralus | northcentralus | scus / ncus |

### Naming Convention

Resources follow: `{type}-radshow-{env}-{region_short}` (e.g. `func-radshow-stg01-cin`, `kv-radshow-stg01-sin`).

---

## Step-by-Step Setup for New Enterprise

### Prerequisites

- Azure subscription with Owner/Contributor + User Access Admin
- GitHub organization with 6 repositories (fork or clone all repos)
- Tools: Azure CLI (`az`), GitHub CLI (`gh`), Terraform ≥ 1.5, Terragrunt ≥ 1.0, Docker, `jq`

### Step 0: Fork Repos & Update Module Sources

1. Fork all 6 repos to your GitHub org.
2. In **radshow-lic**, update all `_envcommon/*.hcl` files — change the module source:
   ```hcl
   # FROM:
   source = "git::https://github.com/DeepMalh44/radshow-def.git//modules/...?ref=main"
   # TO:
   source = "git::https://github.com/YOUR_ORG/radshow-def.git//modules/...?ref=main"
   ```
3. In **radshow-lic**, update the OIDC script's org: `scripts/setup-github-oidc.sh` → `GITHUB_ORG="YOUR_ORG"`.

### Step 1: Update Hardcoded IDs

Edit these files in **radshow-lic** with your Azure subscription and tenant:

| File | Fields to Update |
|------|-----------------|
| `DEV01/env.hcl` | `subscription_id`, `tenant_id` |
| `STG01/env.hcl` | `subscription_id`, `tenant_id` |
| `PRD01/env.hcl` | `subscription_id`, `tenant_id` |
| `STG01/sql-mi/terragrunt.hcl` | `entra_admin_object_id` → your Entra security group Object ID for SQL MI admins |

In **radshow-apim**, update tenant ID in configuration files:

| File | Field |
|------|-------|
| `configuration.dev.yaml` | `tenant-id` named value |
| `configuration.stg.yaml` | `tenant-id` named value |
| `configuration.prd.yaml` | `tenant-id` named value |

### Step 2: Create Terraform State Backend

Before any infrastructure deployment, create the shared state storage:

```bash
az group create --name rg-radshow-tfstate --location <your-primary-region>
az storage account create \
  --name stradshwtfstate \
  --resource-group rg-radshow-tfstate \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false
az storage container create \
  --name tfstate \
  --account-name stradshwtfstate \
  --auth-mode login
```

> Storage account name must be globally unique. If `stradshwtfstate` is taken, choose a new name and update `radshow-lic/terragrunt.hcl` (root) backend block.

### Step 3: Create GitHub Environments

In **each of the 6 repos**, create these environments via GitHub Settings → Environments:

- `DEV01`
- `STG01`
- `PRD01`

Add approval rules / protection rules as needed for STG01 and PRD01.

### Step 4: Run the OIDC Setup Script

The script creates an Entra App Registration, Service Principal, federated credentials, RBAC, and GitHub secrets — all in one shot.

```bash
cd radshow-lic/scripts

# For each environment:
./setup-github-oidc.sh --env DEV01 --org YOUR_ORG
./setup-github-oidc.sh --env STG01 --org YOUR_ORG
./setup-github-oidc.sh --env PRD01 --org YOUR_ORG
```

**Environment variables needed for STG01/PRD01** (if different subscription):
```bash
export STG01_SUBSCRIPTION_ID="your-stg-sub-id"
export STG01_TENANT_ID="your-tenant-id"
export PRD01_SUBSCRIPTION_ID="your-prd-sub-id"
export PRD01_TENANT_ID="your-tenant-id"
```

#### Secrets set automatically by the script

| Repo | Secrets |
|------|---------|
| All 6 repos | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| radshow-lic | `RESOURCE_GROUP` |
| radshow-api | `ACR_NAME`, `FUNC_APP_NAME`, `RESOURCE_GROUP`, `FUNC_APP_SECONDARY_NAME`, `RESOURCE_GROUP_SECONDARY` |
| radshow-spa | `STORAGE_ACCOUNT_NAME`, `STORAGE_ACCOUNT_SECONDARY_NAME`, `RESOURCE_GROUP`, `FRONT_DOOR_RESOURCE_GROUP`, `FRONT_DOOR_PROFILE_NAME`, `FRONT_DOOR_ENDPOINT_NAME` |
| radshow-db | `FUNC_APP_NAME`, `FUNC_APP_SECONDARY_NAME`, `APP_SERVICE_NAME`, `APP_SERVICE_SECONDARY_NAME`, `CONTAINER_APP_NAME`, `CONTAINER_APP_SECONDARY_NAME` |
| radshow-apim | `RESOURCE_GROUP`, `APIM_NAME` |

#### Secrets that must be set MANUALLY after infrastructure is provisioned

| Repo | Secret | Value Source |
|------|--------|-------------|
| radshow-db | `SQL_MI_FQDN` | SQL MI FOG listener endpoint (from `terragrunt output` of `sql-mi-fog` module) |
| radshow-db | `SQL_DATABASE_NAME` | Usually `radshow` |

### Step 5: Deploy Infrastructure with Terragrunt

```bash
cd radshow-lic/STG01

# Set PATH for terragrunt if needed
# Deploy all modules (exclude container-apps if not needed)
terragrunt apply --all --non-interactive \
  --filter "!path:container-apps" \
  --filter "!path:container-apps-secondary" \
  --filter "!path:container-instances" \
  --filter "!path:container-instances-secondary"
```

> SQL MI takes 4-6 hours to provision. Consider deploying it first, then the rest in parallel.

**Dependency order** (Terragrunt handles this automatically):
1. `resource-group` / `resource-group-secondary`
2. `networking` / `networking-secondary` → `vnet-peering`
3. `storage` / `storage-secondary`
4. `key-vault` / `key-vault-secondary`
5. `monitoring`
6. `redis` / `redis-secondary`
7. `container-registry`
8. `sql-mi` / `sql-mi-secondary` → `sql-mi-fog`
9. `apim`
10. `function-app` / `function-app-secondary`
11. `application-gateway` / `application-gateway-secondary`
12. `front-door`
13. `role-assignments`
14. `automation`
15. Private endpoints (`pe-*`)

### Step 6: Deploy Applications (CI/CD Pipelines)

Push to `main` branch in this order:

1. **radshow-api** — Builds Docker image → ACR → deploys to both Function Apps
2. **radshow-db** — Runs EF Core migrations against SQL MI, grants managed identity access to Function App, App Service, AND Container App identities
3. **radshow-spa** — Builds Vue app → uploads to both Storage `$web` containers → purges Front Door cache
4. **radshow-apim** — Publishes API definitions, policies, and named values to APIM

### Step 7: Post-Deployment Manual Steps

After infrastructure and applications are deployed:

#### Key Vault Secrets (for DR automation)

```bash
# Temporarily enable public access
az keyvault update --name kv-radshow-{env}-{primary} -g rg-radshow-{env}-{primary} \
  --public-network-access enabled --default-action Allow -o none

# Set DR secrets
az keyvault secret set --vault-name kv-radshow-{env}-{primary} \
  --name "active-region" --value "{primary_location}"
az keyvault secret set --vault-name kv-radshow-{env}-{primary} \
  --name "failover-password" --value "{your-dr-password}"

# Lock down again
az keyvault update --name kv-radshow-{env}-{primary} -g rg-radshow-{env}-{primary} \
  --public-network-access disabled -o none

# Repeat for secondary KV with same active-region value
```

#### RBAC Upgrades for Function App Managed Identity

The function apps need `Key Vault Secrets Officer` (not just `Secrets User`) to read/write `active-region` during DR:

```bash
# Get function app MI principal ID
PRINCIPAL_ID=$(az functionapp identity show --name func-radshow-{env}-{primary} \
  -g rg-radshow-{env}-{primary} --query principalId -o tsv)

# Assign on both Key Vaults
az role assignment create --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets Officer" \
  --scope "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{kv-name}"
```

#### Container App Private DNS Zones

Internal CAE environments require private DNS zones for cross-VNet resolution. If Terraform doesn't create them automatically (known issue), create manually:

```bash
# Get CAE default domain and static IP
CAE_DOMAIN=$(az containerapp env show -n {cae-name} -g {rg} --query "properties.defaultDomain" -o tsv)
CAE_IP=$(az containerapp env show -n {cae-name} -g {rg} --query "properties.staticIp" -o tsv)

# Create private DNS zone
az network private-dns zone create -g {rg} --name "$CAE_DOMAIN"

# Add wildcard + apex A records
az network private-dns record-set a add-record -g {rg} --zone-name "$CAE_DOMAIN" \
  --record-set-name "*" --ipv4-address "$CAE_IP"
az network private-dns record-set a add-record -g {rg} --zone-name "$CAE_DOMAIN" \
  --record-set-name "@" --ipv4-address "$CAE_IP"

# Link to both VNets (primary + secondary for cross-region resolution)
az network private-dns link vnet create -g {rg} --zone-name "$CAE_DOMAIN" \
  --name "link-vnet-primary" --virtual-network {primary-vnet-id} --registration-enabled false
az network private-dns link vnet create -g {rg} --zone-name "$CAE_DOMAIN" \
  --name "link-vnet-secondary" --virtual-network {secondary-vnet-id} --registration-enabled false
```

Repeat for both primary and secondary region CAEs.

### Step 8: Verify Deployment

Test all routes through Front Door:

```bash
# SPA (static site via AppGW)
curl -s -o /dev/null -w "%{http_code}" https://ep-spa-{hash}.azurefd.net/

# API (via AppGW → APIM → Function App)
curl -s https://ep-spa-{hash}.azurefd.net/api/status

# API products
curl -s https://ep-spa-{hash}.azurefd.net/api/products

# Direct backend health checks
curl -s https://func-radshow-{env}-{primary}.azurewebsites.net/api/healthz
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Docker containers on Function Apps** | CI/CD deploys container images via `az functionapp config container set`, not zip deploy. Terraform ignores `application_stack` drift via `lifecycle.ignore_changes`. |
| **Application Gateway (WAF_v2)** | AppGW per region handles URL path-based routing (`/api/*` → APIM, `/*` → SPA Storage). FD forwards to AppGW on HTTP (port 80) due to self-signed KV certs — FD Premium rejects self-signed SSL even with `enforceCertificateNameCheck=false`. |
| **Container Apps (Products API)** | Internal CAE with VNet integration. APIM routes `/products` to Container Apps. Private DNS zones auto-created by Terraform when `internal_load_balancer_enabled = true`. |
| **FOG listener for all compute** | Function App and Container Apps all use the SQL MI Failover Group listener endpoint, not direct SQL MI FQDN. Ensures automatic DR failover. |
| **APIM subscriptionRequired off** | `radshow-product-api` has `subscriptionRequired: false` so Container Apps can call it without a subscription key. |
| **`cicd_sp_object_id` in env.hcl** | Centralized CICD service principal Object ID used by `role-assignments` module across all environments. |
| **OIDC (no secrets)** | GitHub Actions authenticate to Azure via Workload Identity Federation — no client secrets to rotate. |
| **Terragrunt wraps Terraform** | `radshow-def` has reusable modules; `radshow-lic` has per-environment wiring with dependency management. |
| **APIOps for APIM** | APIM policies/APIs managed as code in `radshow-apim`, published via pipeline (not Terraform). |
| **Single Front Door endpoint** | SPA + API share one endpoint (`ep-spa`) so relative `/api/*` calls work without CORS. |
| **Active-passive FD routing** | AppGW origins use `priority` (1=primary, 2=secondary). Failover swaps priorities. FD health probes use HTTP GET on port 80. |
| **FD→AppGW HTTP forwarding** | FD terminates TLS from clients, forwards to AppGW on HTTP (port 80) over Azure backbone. Root cause: Azure FD Premium rejects self-signed SSL certs even with `enforceCertificateNameCheck=false`. That flag only skips hostname/SAN matching, NOT CA trust chain validation. |
| **Storage public access required** | Storage static website endpoints (`$web`) require `publicNetworkAccess=Enabled` for Front Door to reach them. `allowSharedKeyAccess=false` (MI-only auth for management). |
| **Each region has its own KV** | App Service and Function App in each region point to their local Key Vault (`kv-radshow-{env}-{primary}` / `kv-radshow-{env}-{secondary}`). Both KVs have `active-region` secret set to the same value. |

## DR Automation

### Tier Architecture

| Tier | Mechanism | Region Dependency |
|------|-----------|-------------------|
| **1** | SPA UI → `/api/failover` endpoint | Hits secondary via Front Door if primary down |
| **2** | Azure Automation webhook (dual-region AA) | Both regions have AA — alert fires to whichever is up |
| **3** | Operator runs standalone `runbooks/` scripts | **None** — runs from any workstation with Azure ARM access |

### Automation Module Scripts (`modules/automation/scripts/`)

Headless runbooks deployed to Azure Automation Account via `file()` in Terraform — any script change is deployed on `terragrunt apply`.

| Script | Purpose |
|--------|---------|
| `00-Setup-Environment.ps1` | Initializes DR config (regions, resource names) |
| `01-Check-Health.ps1` | Pre-drill health checks (SQL MI FOG, Redis, FD, KV, APIM, Function Apps) |
| `02-Planned-Failover.ps1` | Orchestrated failover (FOG → FD origins → KV secret) |
| `03-Unplanned-Failover.ps1` | Emergency failover (AllowDataLoss) |
| `04-Planned-Failback.ps1` | Restore to primary region |
| `05-Validate-Failover.ps1` | Post-failover validation |
| `06-Capture-Evidence.ps1` | Capture DR drill evidence |
| `Invoke-DRFailover.ps1` | Master orchestrator |

### Standalone Operator Runbooks (`runbooks/`)

Interactive PowerShell scripts for operator-driven DR drills. These include colored output, confirmation prompts, and E2E CRUD tests.

| Script | Purpose |
|--------|---------|
| `00-setup-environment.ps1` | Interactive auth + config (`az login` or service principal) |
| `01-check-health.ps1` | Pre-drill health check with go/no-go gate |
| `02-planned-failover.ps1` | Graceful failover with operator confirmations at each step |
| `03-unplanned-failover.ps1` | Forced failover with double-confirm danger gate |
| `04-planned-failback.ps1` | Return to primary region with confirmations |
| `05-validate-failover.ps1` | Post-operation validation + E2E CRUD test via Front Door |
| `06-capture-evidence.ps1` | Export JSON evidence + Markdown report to local disk |
| `07-e2e-dr-drill.ps1` | Full E2E orchestrator: Setup→Health→Failover→Soak→Failback→Report |

Quick start:
```bash
# Full E2E drill (automated)
.\07-e2e-dr-drill.ps1 -Environment "stg01" -SoakMinutes 5 -NoPrompt

# Dry run
.\07-e2e-dr-drill.ps1 -Environment "stg01" -DryRun
```

### DR Failover Steps (what the runbooks do)

1. **SQL MI FOG failover** — `az sql instance-failover-group set-primary --location {secondary}`
2. **Front Door origin priority swap** — `og-appgw`: secondary AppGW→P1, primary AppGW→P2
3. **Key Vault active-region update** — set `active-region` secret to secondary region in both KVs
4. **Validation** — health probes, CRUD test via Front Door, region verification

## Terraform State

| Setting | Value |
|---------|-------|
| Resource Group | `rg-radshow-tfstate` |
| Storage Account | `stradshwtfstate` |
| Container | `tfstate` |
| Key Pattern | `{ENV}/{module}/terraform.tfstate` |
| Auth | Azure AD + OIDC (`use_azuread_auth = true`) |

State is shared across all environments. The storage account is **not managed by Terraform** — it's a bootstrap resource.

## Front Door Configuration Details

### Origin Groups & Health Probes

| Origin Group | Health Probe Path | Method | Protocol | Interval | Sample Size | Required Successful | Traffic Restoration |
|-------------|-------------------|--------|----------|----------|-------------|--------------------|--------------------|
| `og-appgw` | `/` | GET | Http | 30s | 4 | 3 | 10 min |

> **Note**: FD probes AppGW via HTTP (port 80). AppGW handles URL path routing to APIM and Storage backends internally.

### Origins (STG01)

| Origin Group | Origin | Hostname | Priority |
|-------------|--------|----------|----------|
| `og-appgw` | `appgw-primary` | `20.235.72.158` (AppGW cin public IP) | 1 |
| `og-appgw` | `appgw-secondary` | `20.219.126.137` (AppGW sin public IP) | 2 |

> **Important**: Origins use AppGW public IPs. `certificate_name_check_enabled = false` because AppGW uses self-signed KV certs. FD forwards via **HttpOnly** to avoid SSL trust chain rejection.

### Routes

| Route | Pattern | Origin Group | Forwarding Protocol | Supported Protocols |
|-------|---------|-------------|--------------------|-----------:|
| `route-all` | `/*` | `og-appgw` | HttpOnly | Http, Https |

> **Note**: A single route passes all traffic to AppGW. AppGW handles path-based routing internally: `/api/*` → APIM backend pool, `/*` → Storage SPA backend pool.

### Application Gateway (WAF_v2) — Per Region

Each region has an AppGW with:
- **HTTPS listener** (port 443) — for direct access (not used by FD)
- **HTTP listener** (port 80) — used by FD (priority 10 routing rule)
- **URL path map**: `/api/*` → `bp-apim`, default → `bp-spa`
- **WAF**: OWASP 3.2, Prevention mode, Host header exclusion (rule 920350)
- **Custom WAF rule**: `X-Azure-FDID` header must match FD resource_guid
- **NSG**: AzureFrontDoor.Backend allowed on port 443 (pri 120) AND port 80 (pri 121)

### Security

- **FD WAF Policy**: Prevention mode, managed rule sets (Default Rule Set + Bot Protection) with custom rate-limiting rules
- **AppGW WAF Policy**: OWASP 3.2, Prevention mode, Host header exclusion for FD IP-based Host headers
- **Front Door ID**: `d6f9998e-db6a-4143-9ba7-71d17c486ece` (STG01) — validated by AppGW custom WAF rule
- **Profile Timeout**: 240 seconds

## Function App Environment Variables

Key app settings configured on Function Apps (set via Terragrunt/Terraform). The Function App acts as the DR orchestrator, so it has settings for both regions, resource group names, and connection details.

### Core Settings

| Setting | Primary Value (cin) | Secondary Value (sin) |
|---------|--------------------|-----------------------|
| `AZURE_REGION` | `centralindia` | `southindia` |
| `KeyVault__VaultUri` | `https://kv-radshow-stg01-cin.vault.azure.net/` | `https://kv-radshow-stg01-sin.vault.azure.net/` |
| `KeyVault__PeerVaultUri` | `https://kv-radshow-stg01-sin.vault.azure.net/` | `https://kv-radshow-stg01-cin.vault.azure.net/` |
| `APIM_GATEWAY_URL` | `https://apim-radshow-stg01-cin.azure-api.net` | `https://apim-radshow-stg01-cin.azure-api.net` |
| `SqlConnection` | `Server=fog-radshow-stg01.fa2e243b64f2.database.windows.net;Database=radshow;Authentication=Active Directory Managed Identity;...` | Same FOG listener |
| `Redis__ConnectionString` | `redis-radshow-stg01-cin.redis.cache.windows.net:6380,...` | `redis-radshow-stg01-sin.redis.cache.windows.net:6380,...` |
| `Storage__AccountName` | `stradshowstg01cin` | `stradshowstg01sin` |

### DR Orchestration Settings

| Setting | Primary Value (cin) | Secondary Value (sin) |
|---------|--------------------|-----------------------|
| `FRONT_DOOR_ORIGIN_GROUP_NAME` | `og-appgw` | `og-appgw` |
| `FRONT_DOOR_PROFILE_NAME` | `afd-radshow-stg01` | `afd-radshow-stg01` |
| `PRIMARY_LOCATION` | `centralindia` | `centralindia` |
| `SECONDARY_LOCATION` | `southindia` | `southindia` |
| `RESOURCE_GROUP_PRIMARY` | `rg-radshow-stg01-cin` | `rg-radshow-stg01-cin` |
| `RESOURCE_GROUP_SECONDARY` | `rg-radshow-stg01-sin` | `rg-radshow-stg01-sin` |
| `SUBSCRIPTION_ID` | `b8383a80-7a39-472f-89b8-4f0b6a53b266` | `b8383a80-7a39-472f-89b8-4f0b6a53b266` |
| `SQL_MI_FOG_NAME` | `fog-radshow-stg01` | `fog-radshow-stg01` |

### Health Check URLs

| Setting | Primary Value (cin) | Secondary Value (sin) |
|---------|--------------------|-----------------------|
| `CONTAINER_APP_HEALTH_URL` | `https://ca-products-radshow-stg01-cin.happysea-a428f96b.centralindia.azurecontainerapps.io/healthz` | `https://ca-products-radshow-stg01-sin.mangosea-b9cd4f1e.southindia.azurecontainerapps.io/healthz` |

> **Note**: `WEBAPP_HEALTH_URL` was removed — App Service is no longer part of the architecture.

> **Important**: Each region's Function App must point to their **local** Key Vault. Both KVs should have the same `active-region` value.

## Managed Identity Reference (STG01)

System-assigned managed identity principal IDs for all compute resources:

| Resource | Region | Principal ID |
|----------|--------|--------------|
| `func-radshow-stg01-cin` | centralindia | `bc01ae81-49a1-4a90-8ef4-12f01a653522` |
| `func-radshow-stg01-sin` | southindia | `d5b130b7-32b5-48dc-9e9d-441cf502f780` |
| `ca-products-radshow-stg01-cin` | centralindia | `46ce9dca-09e5-4b35-9cd1-db5f9084d0af` |
| `ca-products-radshow-stg01-sin` | southindia | `fa3c960e-64ba-4613-88b4-357414ab8b1b` |

CI/CD Service Principal (OIDC): OID `6952ac03-12b8-4bd2-8697-9b624583b14f`

> **Note**: These IDs change if a resource is recreated (e.g., `terragrunt apply` forces recreate on Container Apps). After recreation, re-run `radshow-db` migration pipeline to re-grant SQL MI access to new identities.

## Container App Environment Details (STG01)

| Region | CAE Name | Default Domain | Static IP | DNS Zone |
|--------|----------|---------------|-----------|----------|
| centralindia | (internal) | `happysea-a428f96b.centralindia.azurecontainerapps.io` | `10.1.4.240` | Private DNS zone with `*` + `@` A records, linked to both VNets |
| southindia | (internal) | `mangosea-b9cd4f1e.southindia.azurecontainerapps.io` | (check via `az containerapp env show`) | Private DNS zone with `*` + `@` A records, linked to both VNets |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `terragrunt apply` resets Function App to `DOTNET-ISOLATED\|8.0` | Fixed — `lifecycle.ignore_changes` on `application_stack`. Re-run CI/CD pipeline to restore container. |
| State lock stuck | `terragrunt force-unlock {lock-id}` |
| KV access denied (403) | KVs are locked down. Temporarily enable public access, perform operation, then re-lock. |
| SPA shows stale content | Purge Front Door cache: `az afd endpoint purge ... --content-paths "/*"` |
| Container-apps apply fails | Known issue — `infrastructure_resource_group_name` forces recreate. Deferred. |
| Container App DNS resolution fails | If internal CAE, verify private DNS zone exists with wildcard (`*`) + apex (`@`) A records pointing to CAE static IP. Check VNet links include all relevant VNets (both primary and secondary). |
| Products page HTTP 500 | Check: (1) APIM `radshow-product-api` has `subscriptionRequired: false`, (2) Container App CAE private DNS zone exists, (3) Container App MI has SQL MI database user (granted by `migrate.yml`). |
| FD returns 502 `OriginCertificateSelfSigned` | AppGW uses self-signed KV certs. FD Premium rejects them even with `enforceCertificateNameCheck=false`. Fix: use `forwarding_protocol = HttpOnly` (port 80). |
| FD returns 404 after route recreation | FD global propagation takes 10-25 minutes. Check `deploymentStatus` — `NotStarted` means still propagating. Wait and retry. |
| WAF 403 after enabling Prevention mode | AppGW WAF rule 920350 blocks IP-based Host headers from FD. Add WAF exclusion for `RequestHeaderNames:host`. |
| Function App can't pull ACR images | Ensure `AcrPull` role assigned to Function App MI on ACR + `container_registry_use_managed_identity = true`. |

## Terraform Modules (`radshow-def/modules/`)

| Module | Purpose |
|--------|---------|
| `apim` | Azure API Management instance + regional gateways |
| `application-gateway` | Application Gateway WAF_v2 with URL path routing |
| `automation` | Azure Automation Account + DR runbooks + webhooks |
| `container-apps` | Container App + Container App Environment (internal CAE) |
| `container-instances` | Azure Container Instances |
| `container-registry` | Azure Container Registry (Premium, geo-replicated) |
| `front-door` | Azure Front Door Premium (endpoints, origin groups, origins, routes, WAF) |
| `function-app` | Azure Function App (container-based) + App Service Plan |
| `key-vault` | Azure Key Vault with private endpoint support |
| `monitoring` | Log Analytics Workspace + Application Insights |
| `networking` | VNet + NSGs + 8 subnets |
| `private-endpoint` | Private Endpoints for various services |
| `redis` | Azure Cache for Redis (Premium) |
| `resource-group` | Resource Group with optional management lock |
| `role-assignments` | RBAC role assignments for managed identities + CICD SP |
| `sql-mi` | SQL Managed Instance |
| `sql-mi-fog` | SQL MI Failover Group |
| `storage` | Storage Account with static website + blob containers |
| `vnet-peering` | VNet peering between primary and secondary |

## Terraform Tests (`radshow-def/tests/`)

| Test File | What It Validates |
|-----------|-------------------|
| `dr_config_test.tftest.hcl` | Automation module: runbooks created when `enable_dr_runbooks=true`, skipped when false; dual-AA pattern for primary/secondary |
| `modules_validate.tftest.hcl` | Plan-only validation of resource-group, key-vault, monitoring, automation, storage modules (names match, defaults applied) |
| `resource_locks_test.tftest.hcl` | Management locks on SQL MI, APIM, Key Vault, Resource Group (enabled/disabled toggle for IR-02 compliance) |

Run tests:
```bash
cd radshow-def
terraform test
```

## Additional Documentation

| Document | Location | Purpose |
|----------|----------|---------|
| Operations Guide | `RAD_SHOWCASE_OPERATIONS_GUIDE.md` | Day-to-day operations, pipeline triggers, verification URLs |
| Architecture Notes | `docs/architecture-notes.md` | Detailed architecture decisions, resource inventory |
| Deployment Runbook | `docs/deployment-runbook.md` | Step-by-step first-time deployment guide |
| DR Runbooks README | `runbooks/README.md` | Standalone operator DR drill documentation |
| Implementation Plan | `rad_show_implementationPlan.md` | Original sprint plan (Sprints 1-12, all completed) |
