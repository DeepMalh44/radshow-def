# RAD Showcase Application

Multi-region, DR-capable Azure application with full CI/CD automation across 6 repositories.

---

## Architecture Flow

```
                          ┌──────────────────────────────────────────────────────────┐
                          │                      INTERNET                            │
                          └────────────────────────┬─────────────────────────────────┘
                                                   │
                                                   ▼
                          ┌──────────────────────────────────────────────────────────┐
                          │              AZURE FRONT DOOR (Premium)                  │
                          │                  afd-radshow-{env}                       │
                          │                                                          │
                          │   ep-spa (single endpoint)                               │
                          │     ├─ route-spa  (/*    ) ──► og-spa                   │
                          │     ├─ route-api  (/api/*) ──► og-api                   │
                          │     └─ route-app  (/app/*) ──► og-app                   │
                          └──────┬──────────────────┬──────────────────┬─────────────┘
                                 │                  │                  │
                     ┌───────────▼──────┐ ┌────────▼────────┐ ┌──────▼──────────────┐
                     │  og-spa origins  │ │  og-api origins  │ │   og-app origins    │
                     │ (Storage $web)   │ │ (APIM Gateway)   │ │ (App Service)       │
                     └───────┬──────────┘ └────────┬────────┘ └──────┬──────────────┘
                             │                     │                 │
           ┌─────────────────▼────────┐  ┌─────────▼──────────┐  ┌──▼──────────────────┐
           │ STORAGE ACCOUNT ($web)   │  │ API MANAGEMENT     │  │ APP SERVICE          │
           │ stradshow{env}{region}   │  │ apim-radshow-{env} │  │ app-radshow-{env}    │
           │                          │  │                    │  │ (.NET 8 MVC)         │
           │ Vue 3 SPA static files   │  │ radshow-api (/api) │  │                      │
           │ - index.html             │  │  ├─ /products CRUD │  │ Products web UI      │
           │ - assets/js, css         │  │  ├─ /status        │  │ /app/Products        │
           │ - API calls via /api     │  │  ├─ /healthz       │  │ /app/Products/Create │
           └──────────────────────────┘  │  └─ /failover      │  │                      │
                                         │                    │  │ Calls APIM for data  │
                                         │ radshow-product-api│  │ Connects to SQL MI   │
                                         │  └─ /products CRUD │  │ via FOG listener     │
                                         │    (Container App) │  └──┬───────────────────┘
                                         └──────┬─────┬───────┘     │
                                                │     │             │
                                  ┌─────────────▼──┐  │             │
                                  │ FUNCTION APP   │  │             │
                                  │ func-radshow   │  │             │
                                  │ (.NET 8 Isol.) │  │             │
                                  │ Container/ACR  │  │             │
                                  └─┬──┬──┬──┬─────┘  │             │
                                    │  │  │  │        │             │
                 ┌──────────────┐    │  │  │  │  ┌─────▼───────────┐ │
                 │ SQL MI       │◄───┘  │  │  │  │ CONTAINER APP   │ │
                 │ (FOG)        │◄──────────────┤ │ Products API   │ │
                 └──────────────┘    │  │  │    │ │ ca-product-api  │ │
                 ┌──────────────┐    │  │  │    │ │ (Internal CAE) │ │
                 │ Redis Cache  │◄───┘  │  │    │ └────────────────┘ │
                 │ (Premium)    │       │  │    │                    │
                 └──────────────┘       │  │    │ ┌─ Private DNS ──┐ │
                 ┌──────────────┐       │  │    │ │ *.{cae-domain} │ │
                 │ Key Vault    │◄──────┘  │    │ │ → static IP    │ │
                 └──────────────┘          │    │ └────────────────┘ │
                 ┌──────────────┐          │    │                    │
                 │ Storage      │◄─────────┘    │                    │
                 │ (RA-GZRS)    │               └────────────────────┘
                 └──────────────┘

  All compute (Function App, Container App, App Service) connects to
  SQL MI via the Failover Group listener endpoint for automatic DR.
```

### Request paths

```
  Browser ──► Front Door (/api/*) ──► APIM Gateway ──► Function App ──► SQL MI / Redis / etc.
                 │           │
                 │           └──► Front Door (/app/*) ──► App Service ──► APIM + SQL MI (FOG)
                 │
                 └──► Front Door (/*) ──► Storage $web (SPA static files)

  APIM /products path:  APIM ──► Container App (Products API) ──► SQL MI (FOG listener)
```

**There are zero direct calls from the SPA to any backend.** All API traffic flows through
Front Door and APIM. The SPA uses relative paths (`/api/products`, `/api/status`, etc.) which
Front Door routes to APIM based on the `/api/*` pattern match.

**Products web UI** is served by App Service at `/app/Products` via the `og-app` origin group.
The App Service calls APIM internally for product data and connects to SQL MI via the FOG listener.

---

## Repository Map

| Repo | Purpose | CI/CD Trigger |
|------|---------|---------------|
| **radshow-def** | Reusable Terraform modules (this repo) | `validate.yml` — format + validate on PR; tag releases via `workflow_dispatch` |
| **radshow-lic** | Terragrunt lifecycle — environment configs (DEV01/STG01/PRD01) | `plan.yml` on PR; `apply.yml` via `workflow_dispatch` |
| **radshow-api** | .NET 8 Isolated Function App (container image) | `deploy.yml` — build + ACR push + Function App deploy |
| **radshow-spa** | Vue 3 SPA | `deploy.yml` — npm build + Storage upload + Front Door cache purge |
| **radshow-apim** | APIOps artifacts (API definitions, policies, named values) | `publisher.yml` on push to main; `extractor.yml` on demand |
| **radshow-db** | SQL migration scripts | `migrate.yml` — validate + execute via sqlcmd |

---

## Environments

| Environment | Regions | DR | WAF | Purpose |
|-------------|---------|-----|-----|---------|
| **DEV01** | swedencentral | No | No | Development |
| **STG01** | centralindia + southindia | Yes (active-passive) | Yes | Pre-production |
| **PRD01** | southcentralus + northcentralus | Yes (active-passive) | Yes | Production (RTO ≤ 15 min, RPO ≤ 5 min) |

---

## Deploying the Entire Solution to a New Environment

### Prerequisites

- Azure subscription with Owner or Contributor + User Access Administrator
- GitHub org with these 6 repos
- Terraform >= 1.5.0, Terragrunt >= 0.54.0
- Azure CLI, .NET 8 SDK, Node.js 20
- App registration for OIDC federation (GitHub Actions → Azure)

### Step 1: Setup OIDC Authentication

Create a service principal and configure OIDC federation for GitHub Actions:

```bash
# Create app registration
az ad app create --display-name "radshow-{env}-github"

# Create federated credential for each repo
az ad app federated-credential create --id <APP_OBJECT_ID> \
  --parameters '{"name":"radshow-lic","issuer":"https://token.actions.githubusercontent.com","subject":"repo:DeepMalh44/radshow-lic:environment:{ENV}","audiences":["api://AzureADTokenExchange"]}'

# Repeat for radshow-api, radshow-spa, radshow-apim, radshow-db
```

### Step 2: Setup Terraform State Backend

```bash
az group create -n rg-radshow-tfstate -l <region>
az storage account create -n stradshwtfstate -g rg-radshow-tfstate \
  --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false
az storage container create -n tfstate --account-name stradshwtfstate --auth-mode login
```

### Step 3: Configure Environment Variables

In `radshow-lic/{ENV}/env.hcl`, update:

```hcl
locals {
  subscription_id    = "<YOUR_SUBSCRIPTION_ID>"
  tenant_id          = "<YOUR_TENANT_ID>"
  primary_location   = "<PRIMARY_REGION>"       # e.g. "swedencentral"
  secondary_location = "<SECONDARY_REGION>"      # e.g. "germanywestcentral"
  primary_short      = "<PRIMARY_SHORT>"         # e.g. "swc"
  secondary_short    = "<SECONDARY_SHORT>"       # e.g. "gwc"
  name_prefix        = "radshow-{env}"
  cicd_sp_object_id  = "<CICD_SP_OBJECT_ID>"     # Object ID of sp-radshow-cicd service principal
}
```

### Step 4: Configure GitHub Repository Secrets

Each repo needs these secrets per environment (DEV01, STG01, PRD01):

**All repos:**

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |

**radshow-lic (additional):**

No additional secrets — subscription/tenant come from `env.hcl`.

**radshow-api (additional):**

| Secret | Value |
|--------|-------|
| `ACR_NAME` | ACR name (e.g. `acrradshowdev01`) |
| `FUNC_APP_NAME` | Primary Function App name |
| `RESOURCE_GROUP` | Primary resource group name |
| `FUNC_APP_SECONDARY_NAME` | Secondary Function App name (STG01/PRD01 only) |
| `RESOURCE_GROUP_SECONDARY` | Secondary resource group name (STG01/PRD01 only) |

**radshow-spa (additional):**

| Secret | Value |
|--------|-------|
| `STORAGE_ACCOUNT_NAME` | Primary storage account name |
| `STORAGE_ACCOUNT_SECONDARY_NAME` | Secondary storage account name (STG01/PRD01 only) |
| `FRONT_DOOR_RESOURCE_GROUP` | Front Door resource group |
| `FRONT_DOOR_PROFILE_NAME` | Front Door profile name |
| `FRONT_DOOR_ENDPOINT_NAME` | Front Door endpoint name (e.g. `ep-spa`) |

**radshow-apim (additional):**

| Secret | Value |
|--------|-------|
| `AZURE_RESOURCE_GROUP_NAME` | Resource group containing APIM |
| `API_MANAGEMENT_SERVICE_NAME` | APIM instance name |

**radshow-db (additional):**

| Secret | Value |
|--------|-------|
| `SQL_SERVER` | SQL MI FQDN |
| `SQL_DATABASE` | Database name (e.g. `radshowdb`) |
| `CONTAINER_APP_NAME` | Primary Container App name (e.g. `ca-product-api-radshow-stg01-cin`) |
| `CONTAINER_APP_SECONDARY_NAME` | Secondary Container App name (STG01/PRD01 only) |

### Step 5: Deploy Infrastructure (radshow-lic)

Deploy in dependency order. Terragrunt handles this automatically:

```bash
cd radshow-lic/{ENV}
terragrunt run-all apply --terragrunt-non-interactive -auto-approve
```

**Or via CI/CD:** Push `.hcl` changes to `main` branch — `apply.yml` triggers automatically.

Deployment order (handled by Terragrunt dependency graph):

```
1. resource-group
2. networking, monitoring
3. storage, key-vault, redis, sql-mi, container-registry, apim
4. function-app, container-apps, container-instances, app-service
5. private-endpoints (pe-*)
6. role-assignments
7. front-door
8. automation
```

### Step 6: Create Key Vault Secrets (Post-Deploy)

For DR-enabled environments (STG01, PRD01), create two required secrets in the primary Key Vault:

```bash
# Failover password — authenticates failover requests from the SPA
az keyvault secret set --vault-name kv-radshow-{env}-{region} \
  --name "failover-password" --value "<STRONG_PASSWORD>"

# Active region — tracks which region is currently primary
az keyvault secret set --vault-name kv-radshow-{env}-{region} \
  --name "active-region" --value "<primary_location>"
```

> If Key Vault has public network access disabled, temporarily enable it for CLI access.
> See [DR Operations Guide](https://github.com/DeepMalh44/radshow-lic/blob/main/docs/DR-OPERATIONS-GUIDE.md) for full details.

### Step 7: Run SQL Migrations (radshow-db)

Push migration scripts or trigger `migrate.yml` workflow dispatch.
Runs `sqlcmd` against the SQL MI to create/update the database schema.

### Step 8: Deploy APIM Configuration (radshow-apim)

Push to `main` or trigger `publisher.yml` workflow dispatch.
APIOps publisher syncs API definitions, policies, and named values to APIM.

**Update per-environment config** in `configuration.{env}.yaml`:

```yaml
apimServiceName: apim-radshow-{env}
namedValues:
  - name: backend-url-functions-primary
    properties:
      value: https://func-radshow-{env}.azurewebsites.net/api
  - name: backend-url-functions-secondary
    properties:
      value: https://func-radshow-{env}-secondary.azurewebsites.net/api
apis:
  - name: radshow-api
    properties:
      serviceUrl: https://func-radshow-{env}.azurewebsites.net/api
```

### Step 9: Deploy API (radshow-api)

Push code changes or trigger `deploy.yml` workflow dispatch.
Builds Docker image → pushes to ACR → updates Function App container config.

### Step 10: Deploy SPA (radshow-spa)

Push code changes or trigger `deploy.yml` workflow dispatch.
Builds Vue 3 app → uploads to Storage `$web` → purges Front Door cache.

---

## Deployment Order Summary

Deploy in this exact order for a brand-new environment:

```
1. radshow-lic   →  Infrastructure (Terragrunt apply)
2. Key Vault     →  Create failover-password + active-region secrets (DR envs only)
3. radshow-db    →  Database schema (SQL migrations)
4. radshow-apim  →  APIM APIs, policies, named values (APIOps publisher)
5. radshow-api   →  Function App container image (ACR build + deploy)
6. radshow-spa   →  SPA static files (Storage upload + CDN purge)
```

After initial deployment, repos can be deployed independently in any order
since infrastructure dependencies are already in place.

---

## What to Update When Adding a New Environment

1. **radshow-lic**: Create `{ENV}/` folder — copy from DEV01, update `env.hcl` with new subscription, regions, sizing
2. **radshow-lic**: Add any environment-specific overrides in `{ENV}/*/terragrunt.hcl` files
3. **radshow-apim**: Add `configuration.{env}.yaml` with APIM service name and backend URLs
4. **radshow-api/spa/apim/db**: Add `{ENV}` GitHub environment with the secrets listed above
5. **All workflow files**: Add the new environment to `workflow_dispatch` options if needed

---

## Module Inventory (radshow-def)

| Module | Description |
|---|---|
| `resource-group` | Resource groups with optional resource locks |
| `networking` | VNet, Subnets, NSGs, Private DNS Zones |
| `vnet-peering` | Bidirectional VNet peering between regions |
| `front-door` | Azure Front Door Premium + WAF (active-passive routing) |
| `apim` | API Management Premium with multi-region gateway |
| `app-service` | App Service Plans |
| `function-app` | Azure Functions on Linux with VNet integration |
| `container-apps` | ACA Environment + Container Apps + Private DNS zones for internal environments |
| `container-instances` | Azure Container Instances |
| `container-registry` | ACR with geo-replication |
| `sql-mi` | SQL Managed Instance + Failover Groups |
| `redis` | Redis Cache Premium + Geo-Replication |
| `key-vault` | Key Vault with RBAC + Private Endpoints |
| `storage` | Storage Accounts (RA-GZRS) + static website hosting |
| `private-endpoint` | Reusable Private Endpoint module |
| `monitoring` | Log Analytics + App Insights + DR Alerts |
| `automation` | Azure Automation for DR failover runbooks |
| `role-assignments` | Centralized RBAC assignments |

Modules are consumed by `radshow-lic` via Terragrunt:

```hcl
terraform {
  source = "git::https://github.com/DeepMalh44/radshow-def.git//modules/function-app?ref=main"
}
```

PRD01 pins to a tagged release (`?ref=v1.0.0`). Create tags via `validate.yml` workflow dispatch.

---

## Key Configuration Notes

- **All API traffic goes through APIM** — Front Door `og-api` origins point to APIM gateway, not Function App
- **SPA uses relative paths** — `BASE_URL = '/api'` in `src/services/api.ts`, no hardcoded URLs
- **Function App runs as container** — pulled from ACR via Managed Identity (`container_registry_use_managed_identity = true`)
- **Redis uses access key auth** — `active_directory_authentication_enabled = false`, `public_network_access_enabled = true`
- **AZURE_REGION app setting** — set automatically from `env.hcl` `primary_location` via `_envcommon/function-app.hcl`
- **VNet route all** — `vnet_route_all_enabled = true` ensures all Function App egress goes through VNet
- **Front Door timeout 240s** — `response_timeout_seconds = 240` to support DR failover operations (~120s RTO)
- **Storage public access** — `public_network_access_enabled = true` required for Front Door SPA origins (no Private Link)
- **DR failover roles** — Function App Managed Identities have Key Vault Secrets Officer, SQL MI Contributor, CDN Profile Contributor
- **OIDC everywhere** — all CI/CD pipelines use `ARM_USE_OIDC` / federated credentials, no stored secrets
- **Terraform state** — stored in Azure Storage with AAD auth (`use_azuread_auth = true`)
- **Environment approval gates** — all repos have required reviewer (DeepMalh44) on DEV01, STG01, PRD01 environments
- **DR Operations Guide** — see [radshow-lic/docs/DR-OPERATIONS-GUIDE.md](https://github.com/DeepMalh44/radshow-lic/blob/main/docs/DR-OPERATIONS-GUIDE.md) for failover procedures, KV secrets, and troubleshooting
- **App Service (`og-app`)** — Front Door `route-app` routes `/app/*` to App Service origin group; App Service sets `ASPNETCORE_PATHBASE=/app` and calls APIM internally for product data
- **Container Apps (Products API)** — APIM `radshow-product-api` routes `/products` to internal Container Apps (`ca-product-api-radshow-{env}`); uses VNet-integrated internal CAE with auto-managed private DNS zones
- **FOG listener for all compute** — Function App, App Service, and Container Apps all connect to SQL MI via the Failover Group listener endpoint (not the direct SQL MI FQDN); this ensures automatic DR failover
- **Container App DNS zones** — when `internal_load_balancer_enabled = true`, the `container-apps` module auto-creates a private DNS zone, wildcard + apex A records, and VNet links (controlled by `vnet_ids_for_dns_link` variable)
- **APIM subscriptionRequired** — `radshow-product-api` has `subscriptionRequired: false` so Container Apps and App Service can call it without a subscription key
- **`cicd_sp_object_id` in env.hcl** — centralized CICD service principal Object ID used by `role-assignments` module; avoids hardcoding across per-module configs
- **radshow-db grants Container App identities** — `migrate.yml` grants SQL access to Function App, App Service, AND Container App managed identities in all environments

---

## Prerequisites

- Terraform >= 1.5.0
- AzureRM provider ~> 4.0
- AzAPI provider >= 2.0
- Terragrunt >= 0.54.0
