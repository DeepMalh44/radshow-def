# RAD Showcase — Operations & Deployment Guide

## What Is This?

RAD Showcase is a **multi-region, DR-capable web application** hosted on Azure. It consists of:

- **SPA** (Vue 3) — a product catalog UI served from Azure Blob Storage via Azure Front Door
- **API** (.NET 8 Function App) — a containerized REST API returning product data from SQL Managed Instance
- **APIM** — Azure API Management gateway sitting between Front Door and the Function App
- **SQL MI** — Azure SQL Managed Instance with automatic Failover Group replication to a secondary region

The SPA calls `/api/products` through Front Door → APIM → Function App → SQL MI. All authentication uses **Entra ID managed identities** (zero passwords).

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
**What it deploys:** Resource groups, VNets, SQL MI (primary + secondary), Redis, Key Vault, Storage, Container Registry, App Service Plans, Function Apps, App Services, APIM, Front Door, Private Endpoints, Role Assignments, VNet Peering, Automation Account

```
Trigger:  Actions → "Terragrunt Apply" → Run workflow → select environment
Tool:     Terraform 1.9.8 + Terragrunt 0.54.0
Duration: ~2-4 hours (SQL MI creation is the bottleneck)
```

### Step 2 — Run Database Migrations (`radshow-db`)

**Pipeline:** `migrate.yml`  
**What it does:**
1. Creates the `radshow` database on the primary SQL MI
2. **Grants SQL access** to all 4 managed identities (func-app primary/secondary, app-service primary/secondary)
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
| `app_service_sku` | App Service Plan tier | `S1` |
| `sql_mi_vcores` | SQL MI compute | `4` |
| `sql_mi_storage_gb` | SQL MI storage | `32` |

### APIM per-env config: `radshow-apim/configuration.<env>.yaml`

Contains named values (backend URLs, tenant ID, audience) that get pushed to APIM. Update these to match the resources deployed by radshow-lic.

### Module overrides: `radshow-lic/<ENV>/<module>/terragrunt.hcl`

Each module folder can override `_envcommon` defaults. Common overrides:
- `sql-mi/terragrunt.hcl` — Entra admin login, object ID, principal type
- `function-app/terragrunt.hcl` — App settings (SqlConnection, Redis, KeyVault URLs)
- `app-service/terragrunt.hcl` — Connection strings, app settings
- `front-door/terragrunt.hcl` — Custom domain, WAF association

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
     │  APIM → Func App │     │  Func App        │
     │  App Service      │     │  App Service     │
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
| **Front Door** | Origin priority swap — secondary becomes P1 |
| **Key Vault** | `active-region` secret updated to secondary |
| **Redis** | Geo-replicated — both regions always active |
| **Storage** | Both regions have SPA files — FD routes traffic |

### DR Scripts (`radshow-def/modules/automation/scripts/`)

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

### What to Expect During Failover

1. **Downtime window:** ~2-5 minutes for planned failover (SQL MI FOG sync time)
2. **SPA:** Continues working — Front Door serves from secondary storage
3. **API calls:** Brief interruption while SQL MI switches. After switch, APIM/Front Door route to secondary Function App
4. **Data:** Zero data loss for planned failover. Potential data loss for unplanned (forced) failover
5. **Clients:** No URL changes — Front Door endpoint stays the same

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
| API (Function App direct) | `https://func-radshow-stg01-cin.azurewebsites.net/api/products` |

Quick test:
```bash
curl https://ep-spa-c0gffpf4d5fwdkfr.b02.azurefd.net/api/products
# Should return JSON array of 10 products
```

---

## Authentication Flow Summary

```
GitHub Actions  ──OIDC──►  Azure AD (sp-radshow-cicd)  ──RBAC──►  Azure Resources
                                                                         │
Function App  ──System MI──►  SQL MI (Entra-only auth)                   │
App Service   ──System MI──►  Key Vault (RBAC)                          │
                              Redis                                      │
                              Storage                                    │
```

- **No passwords anywhere.** GitHub → Azure uses OIDC federation. Apps → backends use system-assigned managed identities.
- SQL MI is **Entra-only** (SQL auth disabled). The CI/CD SP (`sp-radshow-cicd`) is the SQL admin and grants access to app managed identities during the `radshow-db` migration pipeline.
