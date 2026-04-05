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
- **Azure Front Door** (Premium) routes traffic: `og-api` → APIM gateways, `og-spa` → Storage static sites, `og-app` → App Service (Products web UI)
- **APIM** proxies all API calls to backend Function Apps (per-region) and routes `/products` to Container Apps (Products API)
- **App Service** serves the Products web UI at `/app/Products` (calls APIM internally for data, connects to SQL MI via FOG listener)
- **Container Apps** run the Products API (`ca-product-api`) in internal (VNet-integrated) Container App Environments with auto-managed private DNS zones
- **SQL MI Failover Group** replicates databases across regions; all compute (Function App, App Service, Container Apps) uses the FOG listener endpoint
- **Redis Cache** deployed independently per region

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
11. `app-service` / `app-service-secondary`
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

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Docker containers on Function Apps** | CI/CD deploys container images via `az functionapp config container set`, not zip deploy. Terraform ignores `application_stack` drift via `lifecycle.ignore_changes`. |
| **Container Apps (Products API)** | Internal CAE with VNet integration. APIM routes `/products` to Container Apps. Private DNS zones auto-created by Terraform when `internal_load_balancer_enabled = true`. |
| **App Service (`og-app`)** | Front Door `/app/*` route to App Service origin group. `ASPNETCORE_PATHBASE=/app` for path-based routing. Connects to SQL MI via FOG listener. |
| **FOG listener for all compute** | Function App, App Service, and Container Apps all use the SQL MI Failover Group listener endpoint, not direct SQL MI FQDN. Ensures automatic DR failover. |
| **APIM subscriptionRequired off** | `radshow-product-api` has `subscriptionRequired: false` so Container Apps and App Service can call it without a subscription key. |
| **`cicd_sp_object_id` in env.hcl** | Centralized CICD service principal Object ID used by `role-assignments` module across all environments. |
| **OIDC (no secrets)** | GitHub Actions authenticate to Azure via Workload Identity Federation — no client secrets to rotate. |
| **Terragrunt wraps Terraform** | `radshow-def` has reusable modules; `radshow-lic` has per-environment wiring with dependency management. |
| **APIOps for APIM** | APIM policies/APIs managed as code in `radshow-apim`, published via pipeline (not Terraform). |
| **Single Front Door endpoint** | SPA + API share one endpoint (`ep-spa`) so relative `/api/*` calls work without CORS. |

## DR Automation

The `modules/automation/scripts/` directory contains PowerShell runbooks deployed to Azure Automation Account:

| Script | Purpose |
|--------|---------|
| `00-Setup-Environment.ps1` | Initializes DR config (regions, resource names) |
| `01-Check-Health.ps1` | Pre-drill health checks (SQL MI FOG, Redis, FD, KV, APIM, Function Apps) |
| `02-Planned-Failover.ps1` | Orchestrated failover (FOG → FD origins → KV secret) |
| `03-Unplanned-Failover.ps1` | Emergency failover |
| `04-Planned-Failback.ps1` | Restore to primary region |
| `05-Validate-Failover.ps1` | Post-failover validation |
| `06-Capture-Evidence.ps1` | Capture DR drill evidence |
| `Invoke-DRFailover.ps1` | Master orchestrator |

Runbooks are inlined into Azure Automation Account via `file()` in Terraform — any script change is deployed on `terragrunt apply`.

## Terraform State

| Setting | Value |
|---------|-------|
| Resource Group | `rg-radshow-tfstate` |
| Storage Account | `stradshwtfstate` |
| Container | `tfstate` |
| Key Pattern | `{ENV}/{module}/terraform.tfstate` |
| Auth | Azure AD + OIDC (`use_azuread_auth = true`) |

State is shared across all environments. The storage account is **not managed by Terraform** — it's a bootstrap resource.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `terragrunt apply` resets Function App to `DOTNET-ISOLATED\|8.0` | Fixed — `lifecycle.ignore_changes` on `application_stack`. Re-run CI/CD pipeline to restore container. |
| State lock stuck | `terragrunt force-unlock {lock-id}` |
| KV access denied (403) | KVs are locked down. Temporarily enable public access, perform operation, then re-lock. |
| SPA shows stale content | Purge Front Door cache: `az afd endpoint purge ... --content-paths "/*"` |
| Container-apps apply fails | Known issue — `infrastructure_resource_group_name` forces recreate. Deferred. |
| Container App DNS resolution fails | If internal CAE, verify private DNS zone exists with wildcard + apex A records pointing to CAE static IP. Check VNet links include all relevant VNets. |
| Products page HTTP 500 | Check: (1) APIM `radshow-product-api` has `subscriptionRequired: false`, (2) Container App CAE private DNS zone exists, (3) Container App MI has SQL MI database user (granted by `migrate.yml`). |
| App Service can't reach SQL MI | Verify `DefaultConnection` uses FOG listener endpoint, not direct SQL MI FQDN. Check that `migrate.yml` granted SQL access to App Service managed identity. |
