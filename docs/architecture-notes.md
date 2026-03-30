# RAD Showcase — Architecture & Deployment Knowledge

## Repository Structure (6 repos, GitHub org: DeepMalh44)

| Repo | Purpose | Key Tech |
|---|---|---|
| `radshow-def` | Terraform modules (reusable blueprint) | 16+ modules under `modules/` |
| `radshow-lic` | Terragrunt lifecycle (env-specific configs) | DEV01/STG01/PRD01 folders, `_envcommon/` shared |
| `radshow-spa` | Vue 3 + Vite + TypeScript SPA | Deploys to Storage `$web` via Front Door |
| `radshow-api` | .NET 8 isolated Azure Functions API | Containerized, deployed via ACR → Function App |
| `radshow-apim` | APIOps config for APIM | API defs, policies, extractor/publisher |
| `radshow-db` | SQL MI schema migrations | Seed data, stored procs |

---

## Azure Resources (DEV01 example — `rg-radshow-dev01-swc`)

- **Subscription**: `b8383a80-7a39-472f-89b8-4f0b6a53b266`
- **Tenant**: `6021aa37-5a44-450a-8854-f08245985be2`
- **Primary region**: swedencentral (swc)
- **Secondary region**: germanywestcentral (gwc)
- **Naming convention**: `{type}-radshow-{env}` or `{type}radshow{env}`

### Key Resources

| Resource | Name | Notes |
|---|---|---|
| Front Door | `afd-radshow-dev01` | Premium, single endpoint `ep-spa` |
| Function App | `func-radshow-dev01` | Container-based, Linux, EP1, system-assigned MI |
| ACR | `acrradshowdev01` | Premium, geo-replicated |
| Storage | `stradshowdev01swc` | RA-GZRS, static website `$web` |
| APIM | `apim-radshow-dev01-swc` | Premium Classic, multi-region gateway |
| SQL MI | `sqlmi-radshow-dev01` | GP_G8IM, failover group `fog-radshow-dev01` |
| Redis | `redis-radshow-dev01` | Premium P1, geo-replication |
| Key Vault | `kv-radshow-dev01-swc` | RBAC, purge protection |
| VNet | `vnet-radshow-dev01-swc` | 10.1.0.0/16, 8 subnets |

### VNet Subnets
`snet-apim`, `snet-app`, `snet-func`, `snet-aca`, `snet-aci`, `snet-redis`, `snet-sqlmi`, `snet-pe`

---

## Front Door Routing

Single endpoint `ep-spa` with two routes:

```
route-spa  →  /*       →  Storage origin group (SPA static files)
route-api  →  /api/*   →  Function App origin group (API backend)
```

Both origin groups use active-passive: primary (priority=1), secondary (priority=2).

> **Previous bug**: Had 2 endpoints (`ep-api` + `ep-spa`). SPA made relative `/api/*` calls which hit Storage instead of Function App. Fixed by consolidating to single endpoint. Applied to all 3 envs in `radshow-lic`.

---

## Function App Container Deployment

The Function App uses **custom container** deployment (not code-based):

1. Image built via `az acr build` (ACR Tasks — cloud-based, no local Docker needed)
2. Image: `acrradshowdev01.azurecr.io/radshow-api:{tag}`
3. Auth: **Managed Identity** (not admin credentials)
   - `acrUseManagedIdentityCreds = true` in site_config
   - `AcrPull` role assigned to Function App system-assigned MI on ACR
4. Terraform variable: `container_registry_use_managed_identity = true` in function-app module
5. Terragrunt: set in `_envcommon/function-app.hcl`

### Deploy commands (manual, for reference — CI/CD handles this):
```bash
# Build in ACR
az acr build --registry acrradshowdev01 --image "radshow-api:latest" --image "radshow-api:dev01" --file Dockerfile .

# Set container on Function App
az functionapp config container set \
  --name func-radshow-dev01 \
  --resource-group rg-radshow-dev01-swc \
  --image "acrradshowdev01.azurecr.io/radshow-api:dev01" \
  --registry-server "acrradshowdev01.azurecr.io"

# Restart to pull new image
az functionapp restart --name func-radshow-dev01 --resource-group rg-radshow-dev01-swc
```

---

## RBAC Role Assignments (role-assignments module)

### DEV01

| Assignment Key | Role | Principal | Scope |
|---|---|---|---|
| `app-kv-secrets` | Key Vault Secrets User | App Service MI | Key Vault |
| `app-storage-blob` | Storage Blob Data Contributor | App Service MI | Storage |
| `func-kv-secrets` | Key Vault Secrets User | Function App MI | Key Vault |
| `func-storage-blob-contributor` | Storage Blob Data Contributor | Function App MI | Storage |
| `func-acr-pull` | AcrPull | Function App MI | ACR |

### STG01/PRD01
Same as DEV01 plus secondary region equivalents (app-sec-*, func-sec-*) for secondary Function Apps, Key Vaults, and Storage accounts. All secondary Function Apps also get `AcrPull` on the same ACR (geo-replicated).

---

## API Endpoints (radshow-api)

| Function | Method | Route | Auth Level |
|---|---|---|---|
| GetProducts | GET | /api/products | Anonymous |
| GetProductById | GET | /api/products/{id} | Anonymous |
| CreateProduct | POST | /api/products | Function |
| UpdateProduct | PUT | /api/products/{id} | Function |
| DeleteProduct | DELETE | /api/products/{id} | Function |
| GetStatus | GET | /api/status | Anonymous |
| HealthCheck | GET/HEAD | /api/healthz | Anonymous |
| TriggerFailover | POST | /api/failover | Function |

### Function App app_settings (from Terragrunt)
```
SqlConnection       = Server={sqlmi-fqdn};Database=radshowdb;Authentication=Active Directory Managed Identity;...
KeyVault__VaultUri   = https://kv-radshow-{env}-{region}.vault.azure.net/
Storage__AccountName = stradshow{env}{region}
Redis__ConnectionString = {hostname}:{ssl_port},password={key},ssl=True,abortConnect=False
```

---

## SPA (radshow-spa)

- **Stack**: Vue 3.4 + Vite 5.2 + TypeScript
- **Views**: RegionalStatusView, ProductInventoryView, FailoverControlView
- **API calls**: `src/services/api.ts` — `BASE_URL = '/api'` (relative, through Front Door)
- **Deploy target**: Storage `$web` container
- **Live URL (DEV01)**: `https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net`

---

## CI/CD Pipelines

### radshow-api `.github/workflows/deploy.yml`
- **Trigger**: push to main (src/**, Dockerfile, *.sln) or workflow_dispatch
- **Jobs**: build → deploy-dev → deploy-stg → deploy-prd (with approval gates)
- **Steps per env**: ACR Tasks build → `az functionapp config container set`
- **Secrets**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ACR_NAME`, `FUNC_APP_NAME`, `RESOURCE_GROUP`

### radshow-spa `.github/workflows/deploy.yml`
- **Trigger**: push to main
- **Steps**: npm ci → build → upload to `$web` → purge Front Door cache

### radshow-lic `.github/workflows/`
- `plan.yml` (on PR): terragrunt plan → post as PR comment
- `apply.yml` (on merge): terragrunt apply (PRD01 requires manual approval)

---

## Known Issues & Fixes

| Issue | Root Cause | Fix |
|---|---|---|
| ACR build NuGet fallback path error | `obj/` folder uploaded to ACR context | `.dockerignore` excluding bin/, obj/ |
| HealthCheck 500 (sync IO) | `WriteString()` not allowed on Kestrel | Changed to `await WriteStringAsync()` |
| Front Door SPA→API routing broken | Separate `ep-api` endpoint | Consolidated to single `ep-spa` endpoint |
| Storage 403 from Front Door | `public_network_access = Disabled` | Set to `true` in `_envcommon/storage.hcl` |
| Function App can't pull ACR images | No AcrPull role, no MI auth | Added role + `container_registry_use_managed_identity = true` |
| Azure CLI Graph API failures | CAE `TokenCreatedWithOutdatedPolicies` | Extract OID from ARM JWT, use `--assignee-object-id` |
| Redis Unhealthy in /api/status | Auth failure on connection | Pending — needs Redis access key or MI auth review |

---

## Terraform Module: function-app

### Key Variables
| Variable | Type | Default | Purpose |
|---|---|---|---|
| `container_registry_use_managed_identity` | bool | false | MI-based ACR pull |
| `storage_uses_managed_identity` | bool | false | MI-based storage access |
| `health_check_path` | string | /api/healthz | Health probe path |
| `service_plan_sku_name` | string | EP1 | App Service Plan SKU |
| `always_on` | bool | true | Keep warm |

### Outputs
`function_app_id`, `function_app_name`, `default_hostname`, `identity_principal_id`, `kind`, `service_plan_id`, `outbound_ip_addresses`

---

## Sprint Status

All 12 sprints COMPLETED:
1. Repo creation + module scaffolding
2. Core infra (RG, networking, VNet peering, DNS, KV, storage, monitoring)
3. Compute (function-app, container-apps, ACI, ACR, ASP)
4. Data (SQL MI + failover group, Redis + geo-replication)
5. Ingress (Front Door active-passive, APIM multi-region, WAF)
6. radshow-api — Product CRUD, Status, Health endpoints
7. radshow-spa — Vue.js SPA (3 views)
8. radshow-apim — APIOps config
9. radshow-db — Schema migrations, seed data
10. Failover orchestration (/api/failover, Automation runbook)
11. CI/CD pipelines for all repos
12. DR runbooks, evidence capture, resource locks, dual-AA approach
