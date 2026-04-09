# RAD Showcase — Operations & Deployment Guide

## What Is This?

RAD Showcase is a **multi-region, DR-capable web application** hosted on Azure. It consists of:

- **SPA** (Vue 3) — a product catalog UI served from Azure Blob Storage via Azure Front Door + Application Gateway
- **API** (.NET 8 Function App) — a containerized REST API returning product data from SQL Managed Instance
- **Products API** (Container App) — a .NET API running in internal Container App Environments, accessed via APIM
- **APIM** — Azure API Management gateway sitting between Application Gateway and compute backends (Function App + Container Apps)
- **Application Gateway** (WAF_v2) — per-region gateway handling URL path-based routing (`/api/*` → APIM, `/*` → Storage SPA)
- **SQL MI** — Azure SQL Managed Instance with automatic Failover Group replication to a secondary region

The SPA calls `/api/products` through Front Door → AppGW → APIM → Function App → SQL MI. All authentication uses **Entra ID managed identities** (zero passwords).

---

## Repository Map

| Repo | Purpose | Pipeline |
|---|---|---|
| `radshow-def` | Terraform modules (shared library) | None — consumed as git source |
| `radshow-lic` | Terragrunt IaC configs per environment | `apply.yml` — deploys infrastructure |
| `radshow-db` | SQL migration scripts | `migrate.yml` — runs migrations + grants SQL access |
| `radshow-api` | .NET 8 Function App (Dockerfile) | `deploy.yml` — builds image + deploys to Function Apps |
| `radshow-apim` | APIM artifacts + per-env configs | `publisher.yml` — publishes API definitions + named values |
| `radshow-spa` | Vue 3 SPA | `deploy.yml` — builds + uploads to blob storage + purges CDN |

---

## Pre-Requisites (One-Time Bootstrap)

These must exist **before** any pipeline runs. They are NOT managed by IaC:

| Item | Details |
|---|---|
| **App Registration** | `sp-radshow-cicd` (App ID: `6bce676a-7cbb-45d1-b60d-a31dbd9562c0`) |
| **Service Principal** | Object ID: `6952ac03-12b8-4bd2-8697-9b624583b14f` |
| **RBAC Roles** | `Contributor` + `User Access Administrator` on the target subscription |
| **Federated Credentials** | 15 total — one per repo per environment (subject: `repo:DeepMalh44/<repo>:environment:<ENV>`) |
| **GitHub Environments** | `DEV01`, `STG01`, `PRD01` on each of the 5 repos (15 total) |
| **GitHub Secrets** (per env) | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| **APIM extra secrets** | `AZURE_RESOURCE_GROUP_NAME` on radshow-apim environments |
| **Terraform State Storage** | Storage account `stradshwtfstate`, container `tfstate` |

> **To add a new environment:** Create the federated credential on the app registration, create the GitHub environment on all 5 repos, and set the 3 OIDC secrets.

---

## Deployment Order (Full End-to-End)

Execute pipelines in this exact order. Each step depends on the previous one completing successfully.

```
Step 1: radshow-lic  (Infrastructure)
         │
Step 2: radshow-db   (Database + SQL user grants)
         │
Step 3: radshow-api  (API container image → Function App)
         │
Step 4: radshow-apim (API gateway configuration)
         │
Step 5: radshow-spa  (Frontend → Blob Storage + CDN purge)
```

### Step 1 — Deploy Infrastructure (`radshow-lic`)

**Pipeline:** `apply.yml` (manual trigger only)  
**What it deploys:** Resource groups, VNets, SQL MI (primary + secondary), Redis, Key Vault, Storage, Container Registry, Function Apps, Application Gateways, APIM, Front Door, Private Endpoints, Role Assignments, VNet Peering, Automation Account

```
Trigger:  Actions → "Terragrunt Apply" → Run workflow → select environment
Tool:     Terraform 1.9.8 + Terragrunt 0.54.0
Duration: ~2-4 hours (SQL MI creation is the bottleneck)
```

### Step 2 — Run Database Migrations (`radshow-db`)

**Pipeline:** `migrate.yml`  
**What it does:**
1. Creates the `radshow` database on the primary SQL MI
2. **Grants SQL access** to all 4 managed identities (func-app primary/secondary, container-app primary/secondary)
3. Creates `__migration_history` tracking table
4. Runs all pending `V###__*.sql` migration files

```
Trigger:  Actions → "SQL Migrations" → Run workflow → select environment
          (Also auto-triggers on push to main when migrations/ changes)
Note:     Migrations run on primary SQL MI only — Failover Group replicates automatically
```

### Step 3 — Deploy API (`radshow-api`)

**Pipeline:** `deploy.yml`  
**What it does:**
1. Builds Docker image via ACR Tasks (tag = git short SHA)
2. Deploys container to Function App (primary + secondary for STG01/PRD01)

```
Trigger:  Actions → "Build & Deploy API" → Run workflow → select environment
          (Also auto-triggers on push to main when src/ changes)
```

### Step 4 — Publish APIM Configuration (`radshow-apim`)

**Pipeline:** `publisher.yml`  
**What it does:** Pushes API definitions, policies, named values (backend URLs, tenant ID, etc.) to APIM using APIOps v6.0.2

```
Trigger:  Actions → "Publish APIM" → Run workflow → select environment
          (Also auto-triggers on push to main when apimartifacts/ changes)
```

### Step 5 — Deploy SPA (`radshow-spa`)

**Pipeline:** `deploy.yml`  
**What it does:**
1. Builds Vue 3 app (`npm run build`)
2. Uploads `dist/` to primary (+secondary) blob storage `$web` container
3. Purges Front Door cache

```
Trigger:  Actions → "Build & Deploy SPA" → Run workflow → select environment
          (Also auto-triggers on push to main when src/ changes)
```

---

## How to Trigger a Pipeline

All pipelines support `workflow_dispatch` (manual trigger):

1. Go to **github.com/DeepMalh44/\<repo\>** → **Actions** tab
2. Select the workflow from the left sidebar
3. Click **"Run workflow"** → select branch `main` → choose environment (`DEV01`/`STG01`/`PRD01`) → **Run**

**Or via CLI:**
```bash
gh workflow run <workflow>.yml --repo DeepMalh44/<repo> -f environment=STG01
```

**Monitor progress:**
```bash
gh run list --repo DeepMalh44/<repo> --limit 3
gh run watch <run-id> --repo DeepMalh44/<repo>
```

---

## Variables to Modify Per Environment

### Primary config: `radshow-lic/<ENV>/env.hcl`

This is the **single source of truth** for each environment. Key variables:

| Variable | What It Controls | Example (STG01) |
|---|---|---|
| `environment` | Environment name | `STG01` |
| `subscription_id` | Target Azure subscription | `b8383a80-...` |
| `primary_location` | Primary Azure region | `centralindia` |
| `secondary_location` | DR region | `southindia` |
| `primary_short` / `secondary_short` | Short region codes for naming | `cin` / `sin` |
| `name_prefix` | Resource naming prefix | `radshow-stg01` |
| `enable_dr` | Deploy secondary region resources | `true` |
| `enable_waf` | Enable WAF on Front Door | `true` |
| `enable_delete_lock` | Prevent accidental deletion | `false` (true for PRD) |
| `app_service_sku` | ~~Removed~~ | N/A |
| `sql_mi_vcores` | SQL MI compute | `4` |
| `sql_mi_storage_gb` | SQL MI storage | `32` |

### APIM per-env config: `radshow-apim/configuration.<env>.yaml`

Contains named values (backend URLs, tenant ID, audience) that get pushed to APIM. Update these to match the resources deployed by radshow-lic.

### Module overrides: `radshow-lic/<ENV>/<module>/terragrunt.hcl`

Each module folder can override `_envcommon` defaults. Common overrides:
- `sql-mi/terragrunt.hcl` — Entra admin login, object ID, principal type
- `function-app/terragrunt.hcl` — App settings (SqlConnection, Redis, KeyVault URLs)
- `application-gateway/terragrunt.hcl` — Backend pools, SSL cert, Front Door ID
- `front-door/terragrunt.hcl` — AppGW origins, WAF association

---

## Environment Comparison

| Setting | DEV01 | STG01 | PRD01 |
|---|---|---|---|
| Regions | swedencentral / germanywestcentral | centralindia / southindia | southcentralus / northcentralus |
| DR Enabled | No | Yes | Yes |
| WAF | No | Yes | Yes |
| Delete Lock | No | No | Yes |
| SQL MI vCores | 4 | 4 | 8 |
| Module source tag | `main` | `main` | `v1.0.0` |

---

## Disaster Recovery & Failover Testing

### Architecture

```
                    ┌─────────────┐
                    │  Front Door │
                    └──────┬──────┘
               ┌───────────┴───────────┐
               ▼                       ▼
     ┌─────────────────┐     ┌─────────────────┐
     │ Primary Region   │     │ Secondary Region │
     │  AppGW (WAF_v2)   │     │  AppGW (WAF_v2)  │
     │  APIM → Func App  │     │  Func App        │
     │  APIM → Cont.App  │     │  Container App   │
     │  SQL MI (Read/W)  │     │  SQL MI (Read)   │
     │  Redis            │     │  Redis           │
     │  Storage ($web)   │     │  Storage ($web)  │
     │  Key Vault        │     │  Key Vault       │
     └─────────────────┘     └─────────────────┘
               │                       │
               └───── SQL MI FOG ──────┘
                  (auto-replication)
```

### What Gets Failed Over

| Component | Failover Mechanism |
|---|---|
| **SQL MI** | Failover Group — switches read-write to secondary |
| **Front Door** | Origin priority swap — `og-appgw`: secondary AppGW→P1, primary AppGW→P2 |
| **Container Apps** | Uses FOG listener endpoint — automatically connects to new primary after SQL MI failover |
| **Key Vault** | `active-region` secret updated to secondary |
| **Redis** | Geo-replicated — both regions always active |
| **Storage** | Both regions have SPA files — FD routes traffic |

### DR Execution Resilience Tiers

DR can be triggered through three independent mechanisms, each with different region dependencies:

| Tier | Mechanism | Region Dependency |
|------|-----------|-------------------|
| **1** | SPA UI → `/api/failover` endpoint | Hits secondary via Front Door if primary down |
| **2** | Azure Automation webhook (dual-region AA) | Both regions have AA — alert fires to whichever is up |
| **3** | Operator runs standalone `runbooks/` scripts | **None** — runs from any workstation with Azure ARM access |

### Automation Module Scripts (`radshow-def/modules/automation/scripts/`)

Headless runbooks deployed to Azure Automation Account via `file()` in Terraform — any script change is deployed on `terragrunt apply`.

| Script | Purpose |
|---|---|
| `00-Setup-Environment.ps1` | Initialize config, authenticate via Managed Identity |
| `01-Check-Health.ps1` | Pre-drill health: SQL FOG sync, Redis, FD, Key Vault |
| `02-Planned-Failover.ps1` | Graceful failover (zero data loss) |
| `03-Unplanned-Failover.ps1` | Forced failover (**may cause data loss**) |
| `04-Planned-Failback.ps1` | Return traffic to primary region |
| `05-Validate-Failover.ps1` | Verify everything switched correctly |
| `06-Capture-Evidence.ps1` | Export drill evidence as JSON (compliance) |
| `Invoke-DRFailover.ps1` | Azure Automation Runbook — can be triggered by alert |

### Standalone Operator Runbooks (`radshow-def/runbooks/`)

Interactive PowerShell scripts for operator-driven DR drills. These include colored output, confirmation prompts, and E2E CRUD tests. They have **no Azure region dependency** — they work from any internet-connected workstation with Azure ARM access.

| Script | Purpose |
|---|---|
| `00-setup-environment.ps1` | Interactive auth + config (`az login` or service principal) |
| `01-check-health.ps1` | Pre-drill health check with go/no-go gate |
| `02-planned-failover.ps1` | Graceful failover with operator confirmations at each step |
| `03-unplanned-failover.ps1` | Forced failover with double-confirm danger gate (AllowDataLoss) |
| `04-planned-failback.ps1` | Return to primary region with confirmations |
| `05-validate-failover.ps1` | Post-operation validation + E2E CRUD test via Front Door |
| `06-capture-evidence.ps1` | Export JSON evidence + Markdown report to local disk |
| `07-e2e-dr-drill.ps1` | Full E2E orchestrator: Setup→Health→Failover→Soak→Failback→Report |

Quick start:
```powershell
# Full E2E drill (automated)
.\07-e2e-dr-drill.ps1 -Environment "stg01" -SoakMinutes 5 -NoPrompt

# Dry run
.\07-e2e-dr-drill.ps1 -Environment "stg01" -DryRun
```

### Running a Planned Failover Test

```powershell
# 1. Setup
. ./00-Setup-Environment.ps1 -ProjectName "radshow" -Environment "STG01" `
    -PrimaryRegion "centralindia" -SecondaryRegion "southindia"

# 2. Health check
. ./01-Check-Health.ps1

# 3. Failover (add -DryRun to simulate)
. ./02-Planned-Failover.ps1
# What happens:
#   - SQL MI FOG switches read-write to secondary (waits up to 5 min for sync)
#   - Front Door origin priorities swap (secondary = P1, primary = P2)
#   - Key Vault active-region updated to secondary

# 4. Validate
. ./05-Validate-Failover.ps1 -OperationType "failover"

# 5. Capture evidence
. ./06-Capture-Evidence.ps1

# 6. Failback to primary
. ./04-Planned-Failback.ps1

# 7. Validate failback
. ./05-Validate-Failover.ps1 -OperationType "failback"
```

### DR Failover Steps (what the runbooks do)

1. **SQL MI FOG failover** — `az sql instance-failover-group set-primary --location {secondary}`
2. **Front Door origin priority swap** — `og-appgw`: secondary AppGW→P1, primary AppGW→P2
3. **Key Vault active-region update** — set `active-region` secret to secondary region in both KVs
4. **Validation** — health probes, CRUD test via Front Door, region verification

### What to Expect During Failover

1. **Downtime window:** ~2-5 minutes for planned failover (SQL MI FOG sync time, 60-minute grace period)
2. **SPA:** Continues working — Front Door serves from secondary storage
3. **API calls:** Brief interruption while SQL MI switches. After switch, APIM/Front Door/AppGW route to secondary Function App
4. **Data:** Zero data loss for planned failover. Potential data loss for unplanned (forced) failover
6. **Clients:** No URL changes — Front Door endpoint stays the same

### SPA Failover Control Panel (In-App UI)

The SPA includes a built-in **Failover Control** page that lets operators trigger DR directly from the browser — no terminal or Azure portal needed.

**Two ways to trigger failover:**

| Method | Best For |
|---|---|
| **SPA UI buttons** (below) | Quick planned failover/failback with visual feedback |
| **PowerShell scripts** (above) | Full DR drills with health checks, evidence capture, and unplanned (forced) failover |

#### Failover Control View (`/failover`)

| Button | Color | Action |
|---|---|---|
| **"Failover to Secondary"** | Red | Switches all traffic to the secondary region |
| **"Failback to Primary"** | Blue | Returns all traffic to the primary region |

Both buttons prompt for a **password** (stored as `failover-password` secret in Key Vault) before executing.

#### What Happens When You Click

The Function App (`POST /api/failover`) runs a 6-step orchestration using the Azure ARM SDK:

| Step | Action | Detail |
|---|---|---|
| 1 | Validate password | Reads `failover-password` from Key Vault |
| 2 | Check active region | Reads `active-region` from Key Vault; blocks no-op if already in target |
| 3 | **SQL MI FOG switch** | `InstanceFailoverGroupResource.FailoverAsync()` — graceful, zero data loss |
| 4 | Stabilization wait | 10-second delay for replication sync |
| 5 | **Front Door origin swap** | Sets new primary origin to priority 1, old to priority 2 |
| 6 | **Update Key Vault** | Writes new `active-region` value |

The UI shows a live elapsed timer during execution and then a step-by-step results table with status badges and durations.

#### Regional Status View (`/status`)

Shows real-time health of both regions:
- Current region and active region
- Component health (SQL MI, Redis, Function App) with latency measurements
- **"Refresh"** button calls `GET /api/status`

#### SPA vs PowerShell — Key Difference

The SPA only performs **planned (graceful) failover**. It does NOT support `AllowDataLoss` forced failover — that's intentionally restricted to the PowerShell script `03-Unplanned-Failover.ps1` to prevent accidental data loss from a web UI.

### Automated Trigger via Azure Automation

`Invoke-DRFailover.ps1` runs as a Runbook. It can be triggered by:
- Azure Monitor alert (via webhook — parses Common Alert Schema)
- Manual execution with params: `-FailoverType Planned|Forced -Action failover|failback`

---

## Verification URLs (STG01)

| What | URL |
|---|---|
| SPA | `https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/` |
| API (via Front Door) | `https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/api/products` |
| API (via APIM direct) | `https://apim-radshow-stg01-cin.azure-api.net/api/products` |
| Products API (via APIM) | `https://apim-radshow-stg01-cin.azure-api.net/products` |
| API (Function App direct) | `https://func-radshow-stg01-cin.azurewebsites.net/api/products` |
| Health check (API) | `https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/api/healthz` |
| Failover Control | `https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/failover` |
| Regional Status | `https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/status` |

Quick test:
```bash
# Front Door routes (single route via AppGW)
curl -s -o /dev/null -w "SPA: %{http_code}\n" https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/
curl -s -o /dev/null -w "API: %{http_code}\n" https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/api/status

# Direct backend health check
curl -s https://func-radshow-stg01-cin.azurewebsites.net/api/healthz
```

---

## Front Door Configuration Details

### Origin Group & Health Probe

| Origin Group | Health Probe Path | Method | Protocol | Interval | Sample Size | Required Successful | Traffic Restoration |
|-------------|-------------------|--------|----------|----------|-------------|--------------------|--------------------|---|
| `og-appgw` | `/` | GET | Http | 30s | 4 | 2 | 10 min |

> **Note**: Front Door uses a single origin group (`og-appgw`) that routes to Application Gateway. The AppGW then handles URL-path-based routing to APIM (`/api/*`) and Storage SPA (`/*`).

### Origins (STG01)

| Origin Group | Origin | Hostname (AppGW Public IP) | Priority |
|-------------|--------|----------|----------|
| `og-appgw` | `appgw-primary` | `20.235.72.158` (appgw-radshow-stg01-cin) | 1 |
| `og-appgw` | `appgw-secondary` | `20.219.126.137` (appgw-radshow-stg01-sin) | 2 |

### Routes

| Route | Pattern | Origin Group | Forwarding Protocol | Cache | Compression |
|-------|---------|-------------|---------------------|-------|-------------|
| `route-all` | `/*` | `og-appgw` | HttpOnly | None | No |

> **Note**: Front Door forwards all traffic to Application Gateway over HTTP (port 80). This avoids `OriginCertificateSelfSigned` errors caused by self-signed KV certificates on AppGW HTTPS listeners. AppGW handles URL-path routing and WAF inspection.

### Application Gateway (per region)

| Component | Primary (cin) | Secondary (sin) |
|-----------|--------------|------------------|
| **Name** | `appgw-radshow-stg01-cin` | `appgw-radshow-stg01-sin` |
| **SKU** | WAF_v2 | WAF_v2 |
| **Listeners** | HTTP (port 80), HTTPS (port 443) | HTTP (port 80), HTTPS (port 443) |
| **URL Path Map** | `/api/*` → APIM backend, `/*` → Storage SPA backend | Same |
| **WAF Mode** | Prevention (OWASP 3.2) | Prevention (OWASP 3.2) |
| **WAF Exclusion** | Host header, rule 920350 (FD sends IP-based Host headers) | Same |
| **NSG** | Port 80 from `AzureFrontDoor.Backend` (pri 121) | Same |

### WAF & Security

- **Front Door WAF**: Prevention mode, Default Rule Set + Bot Protection, rate-limiting custom rules
- **AppGW WAF**: Prevention mode, OWASP 3.2, Host header exclusion for rule 920350
- **Front Door ID**: `d6f9998e-db6a-4143-9ba7-71d17c486ece` (STG01) — used for `X-Azure-FDID` header validation
- **Profile Timeout**: 240 seconds

---

## Environment Variables Reference

### Function App Settings

| Setting | Primary (cin) | Secondary (sin) |
|---------|--------------|------------------|
| `AZURE_REGION` | `centralindia` | `southindia` |
| `KeyVault__VaultUri` | `https://kv-radshow-stg01-cin.vault.azure.net/` | `https://kv-radshow-stg01-sin.vault.azure.net/` |
| `KeyVault__PeerVaultUri` | `https://kv-radshow-stg01-sin.vault.azure.net/` | `https://kv-radshow-stg01-cin.vault.azure.net/` |
| `FRONT_DOOR_ORIGIN_GROUP_NAME` | `og-appgw` | `og-appgw` |
| `FRONT_DOOR_PROFILE_NAME` | `afd-radshow-stg01` | `afd-radshow-stg01` |
| `APIM_GATEWAY_URL` | `https://apim-radshow-stg01-cin.azure-api.net` | `https://apim-radshow-stg01-cin.azure-api.net` |
| `SqlConnection` | FOG listener (`fog-radshow-stg01.fa2e243b64f2.database.windows.net`) | Same FOG listener |
| `CONTAINER_APP_HEALTH_URL` | `https://ca-products-radshow-stg01-cin.happysea-a428f96b.centralindia.azurecontainerapps.io/healthz` | `https://ca-products-radshow-stg01-sin.mangosea-b9cd4f1e.southindia.azurecontainerapps.io/healthz` |

> **Note**: `WEBAPP_HEALTH_URL` has been removed — App Service is no longer part of the architecture.

> **Critical**: Each region's Function App must point to their **local** Key Vault. A prior bug had the sin Function App pointing to the cin KV — this caused incorrect region data to be served.

---

## Key Design Decisions

| Decision | Rationale |
|----------|----------|
| **Docker containers on Function Apps** | CI/CD deploys container images via `az functionapp config container set`, not zip deploy. Terraform ignores `application_stack` drift via `lifecycle.ignore_changes`. |
| **FOG listener for all compute** | Function App and Container Apps use the SQL MI Failover Group listener endpoint, not direct SQL MI FQDN. Ensures automatic DR failover. |
| **Application Gateway (WAF_v2) per region** | AppGW provides URL-path routing (`/api/*` → APIM, `/*` → Storage SPA) and WAF inspection. Front Door routes all traffic to AppGW. |
| **FD → AppGW HTTP forwarding** | Front Door forwards to AppGW over HTTP (port 80) to avoid `OriginCertificateSelfSigned` errors from self-signed KV certificates on HTTPS listeners. |
| **Single Front Door origin group & route** | `og-appgw` with `route-all` (`/*`) replaces the previous 3-origin-group setup. AppGW handles path-based routing instead of FD. |
| **Active-passive FD routing** | Origins use `priority` (1=primary, 2=secondary). Failover swaps priorities. Health probes use GET requests to detect origin availability. |
| **Storage public access required** | Storage static website endpoints (`$web`) require `publicNetworkAccess=Enabled` for AppGW backend. `allowSharedKeyAccess=false` (MI-only auth for management). |
| **Each region has its own KV** | Function App in each region points to their local Key Vault. Both KVs have `active-region` secret set to the same value. |
| **3-tier DR resilience** | SPA UI (Tier 1), Azure Automation webhooks (Tier 2), and operator scripts (Tier 3) provide independent failover paths with no single point of failure. |
| **OIDC (no secrets)** | GitHub Actions authenticate via Workload Identity Federation — no client secrets to rotate. |
| **APIOps for APIM** | APIM policies/APIs managed as code in `radshow-apim`, published via pipeline (not Terraform). |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `terragrunt apply` resets Function App to `DOTNET-ISOLATED\|8.0` | Fixed — `lifecycle.ignore_changes` on `application_stack`. Re-run CI/CD pipeline to restore container. |
| State lock stuck | `terragrunt force-unlock {lock-id}` |
| KV access denied (403) | KVs are locked down. Temporarily enable public access, perform operation, then re-lock. |
| SPA shows stale content | Purge Front Door cache: `az afd endpoint purge ... --content-paths "/*"` |
| Container-apps apply fails | Known issue — `infrastructure_resource_group_name` forces recreate. Deferred. |
| Container App DNS resolution fails | If internal CAE, verify private DNS zone exists with wildcard (`*`) + apex (`@`) A records pointing to CAE static IP. Check VNet links include both primary and secondary VNets. |
| Products page HTTP 500 | Check: (1) APIM `radshow-product-api` has `subscriptionRequired: false`, (2) Container App CAE private DNS zone exists, (3) Container App MI has SQL MI database user (granted by `migrate.yml`). |
| `OriginCertificateSelfSigned` on FD | Front Door cannot validate self-signed KV certs on AppGW HTTPS listeners. Fixed by using `HttpOnly` forwarding protocol on FD route — FD connects to AppGW over port 80. |
| WAF 403 on FD requests | AppGW WAF rule 920350 blocks requests with IP-based Host headers (sent by FD). Fixed by adding Host header exclusion for rule 920350 in AppGW WAF policy. |
| FD returns 404 after route recreation | FD global propagation takes 10-25 minutes. Check `deploymentStatus` — `NotStarted` means still propagating. Wait and retry. |
| Function App can't pull ACR images | Ensure `AcrPull` role assigned to Function App MI on ACR + `container_registry_use_managed_identity = true`. |

---

## Authentication Flow Summary

```
GitHub Actions  ──OIDC──►  Azure AD (sp-radshow-cicd)  ──RBAC──►  Azure Resources
                                                                         │
Function App  ──System MI──►  SQL MI (Entra-only auth)                   │
Container App ──System MI──►  SQL MI (FOG listener)                     │
                              Redis                                      │
                              Storage                                    │
```

- **No passwords anywhere.** GitHub → Azure uses OIDC federation. Apps → backends use system-assigned managed identities.
- SQL MI is **Entra-only** (SQL auth disabled). The CI/CD SP (`sp-radshow-cicd`) is the SQL admin and grants access to app managed identities (Function App, Container App) during the `radshow-db` migration pipeline.

---

## TODO: Enable Alert-Driven Automatic Failover

The Terraform modules support fully automatic failover triggered by Azure Monitor alerts, but it requires configuring the IaC inputs. The chain works as follows:

```
Azure Monitor metric alert fires (e.g., SQL MI availability < 95%)
        │
        ▼
Action Group → automation_runbook_receiver
        │
        ▼
Automation Account webhook → Invoke-DRFailover.ps1
        │
        ▼
SQL MI FOG switch → Front Door origin swap → Key Vault update
```

The runbook (`Invoke-DRFailover.ps1`) already parses the **Common Alert Schema** from webhooks, authenticates via Managed Identity, and runs the full orchestration. All module code is built — only the Terragrunt config values need to be set.

### Step 1 — Enable DR Runbooks & Webhook

**File:** `radshow-lic/<ENV>/automation/terragrunt.hcl`

Add these inputs:

```hcl
inputs = {
  enable_dr_runbooks = true    # deploys all 7 DR scripts as Azure Automation Runbooks
  enable_dr_webhook  = true    # creates webhook endpoint that alerts can call
}
```

This deploys the `Invoke-DRFailover` runbook and exposes a webhook URI. The webhook URI is output as `dr_webhook_uri` (sensitive).

### Step 2 — Define Alert Rules

**File:** `radshow-lic/<ENV>/monitoring/terragrunt.hcl`

Add `enable_dr_alerts = true` and define the metric conditions that should trigger failover:

```hcl
inputs = {
  enable_dr_alerts = true

  dr_alert_definitions = {
    "alert-sqlmi-availability" = {
      description = "SQL MI availability dropped below 95%"
      severity    = 0          # Critical
      frequency   = "PT1M"    # Check every minute
      window_size = "PT5M"    # Over a 5-minute window
      scopes      = [dependency.sql_mi.outputs.id]
      criteria = {
        metric_namespace = "Microsoft.Sql/managedInstances"
        metric_name      = "avg_cpu_percent"       # or a custom availability metric
        aggregation      = "Average"
        operator         = "GreaterThan"
        threshold        = 95                       # CPU > 95% as a proxy
      }
    }
    "alert-funcapp-errors" = {
      description = "Function App 5xx error rate exceeded threshold"
      severity    = 1
      frequency   = "PT1M"
      window_size = "PT5M"
      scopes      = [dependency.function_app.outputs.id]
      criteria = {
        metric_namespace = "Microsoft.Web/sites"
        metric_name      = "Http5xx"
        aggregation      = "Total"
        operator         = "GreaterThan"
        threshold        = 50
      }
    }
  }
}
```

### Step 3 — Wire Action Group to Automation Webhook

In the same `monitoring/terragrunt.hcl`, connect the action group to the automation webhook so alerts trigger the runbook:

```hcl
inputs = {
  action_group_name       = "ag-dr-failover-<ENV>"
  action_group_short_name = "dr-fo"

  dr_automation_webhook_receivers = [
    {
      name                  = "primary-aa-failover"
      automation_account_id = dependency.automation.outputs.id
      runbook_name          = "Invoke-DRFailover"
      webhook_resource_id   = dependency.automation.outputs.id   # Automation Account ID
      is_global_runbook     = false
      service_uri           = dependency.automation.outputs.dr_webhook_uri
    }
  ]
}
```

> **Tip for resilience:** Deploy a second Automation Account in the secondary region and add a second entry to `dr_automation_webhook_receivers`. If the primary region is completely down, the secondary AA will still receive the alert and execute failover.

### Step 4 — Grant Automation Account RBAC

The Automation Account's Managed Identity needs permissions to perform failover:

| Role | Scope | Purpose |
|---|---|---|
| `SQL Managed Instance Contributor` | SQL MI resource group(s) | Switch Failover Group |
| `CDN Profile Contributor` | Front Door resource group | Swap origin priorities |
| `Key Vault Secrets Officer` | Key Vault | Read/write `active-region` secret |

Add these to `radshow-lic/<ENV>/role-assignments/terragrunt.hcl`.

### Step 5 — Deploy & Test

1. Run `terragrunt apply` for the `automation` and `monitoring` modules
2. Verify the runbook and webhook exist in the Azure portal
3. Verify the alert rules and action group are created
4. Test with a dry-run: manually trigger the `Invoke-DRFailover` runbook in the portal with `FailoverType = Planned`, `Action = failover`
5. Verify the alert chain by temporarily lowering the threshold to trigger a test alert

### Summary of Files to Modify

| File | What to Set |
|---|---|
| `radshow-lic/<ENV>/automation/terragrunt.hcl` | `enable_dr_runbooks = true`, `enable_dr_webhook = true` |
| `radshow-lic/<ENV>/monitoring/terragrunt.hcl` | `enable_dr_alerts = true`, `dr_alert_definitions`, `dr_automation_webhook_receivers`, `action_group_name` |
| `radshow-lic/<ENV>/role-assignments/terragrunt.hcl` | RBAC for Automation Account MI |
