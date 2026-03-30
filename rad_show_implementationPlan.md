# RAD Showcase App — Full Implementation Plan

---

## PHASE 0: Repository Setup

**Project name**: `radshow` (all repos under the same GitHub Enterprise org)

> **Regions are fully configurable.** The default pairing is Southcentral US / Northcentral US, but all Terraform modules and Terragrunt configs accept `primary_location` and `secondary_location` as input variables. Changing regions requires only updating `env.hcl` in `radshow-lic` — no module code changes. All resource names, subnet CIDRs, AZ settings, and DNS zones derive from the chosen regions via locals.

### 3 Repository Classes (per PR-01 through PR-04)

| Repo | Purpose | Contents |
|---|---|---|
| `radshow-def` | Terraform definitions (the reusable blueprint) | All Terraform modules, module contracts, no env-specific values |
| `radshow-lic` | GitOps lifecycle controller | Terragrunt configs, environment branches (`DEV01`, `STG01`, `PRD01`), env-specific tfvars, CD pipelines |
| `radshow-spa` | Vue.js SPA frontend | Vue 3 app, builds to static bundle, deploys to Storage `$web` container |
| `radshow-api` | Backend APIs (.NET 8) | Functions + ACA container image code, Product Inventory CRUD, Regional Status, Failover orchestration |
| `radshow-apim` | APIM configuration (APIOps) | API definitions, policies, named values — managed via Azure APIOps Toolkit extractor/publisher |
| `radshow-db` | Database artifacts | SQL MI seed scripts, schema migrations, stored procedures |

**Branching strategy for `radshow-lic`:**
- Branch `DEV01` → deploys to DEV environment
- Branch `STG01` → deploys to STG environment
- Branch `PRD01` → deploys to PRD environment (with approval gates)

Each branch references a **pinned version** (git tag/commit SHA) of `radshow-def`.

---

## PHASE 1: Infrastructure Definitions (`radshow-def`)

### 1.1 Module Structure

```
radshow-def/
├── modules/
│   ├── resource-group/           # RG with optional resource locks
│   ├── networking/               # VNet, Subnets, NSGs, Private DNS Zones
│   ├── vnet-peering/             # Bidirectional VNet peering
│   ├── front-door/               # Front Door Premium + WAF + active-passive routing
│   ├── apim/                     # APIM Premium Classic + multi-region gateway
│   ├── app-service/              # App Service Plan (for Functions hosting)
│   ├── function-app/             # Azure Functions on App Service Plans
│   ├── container-apps/           # ACA Environment + Container Apps
│   ├── container-instances/      # ACI container groups
│   ├── container-registry/       # ACR with geo-replication
│   ├── sql-mi/                   # SQL MI + Failover Group
│   ├── redis/                    # Redis Premium + Geo-Replication
│   ├── key-vault/                # Key Vault + Private Endpoint + RBAC
│   ├── storage/                  # Storage Account (RA-GZRS) + $web static hosting
│   ├── private-endpoint/         # Reusable PE module
│   ├── monitoring/               # Log Analytics + App Insights + Alerts
│   ├── automation/               # Azure Automation for DR failover runbooks
│   └── role-assignments/         # Centralized RBAC assignments
├── tests/                        # Terraform validation tests
└── README.md
```

### 1.2 Region Configuration

All region references are driven by two variables and a lookup map:

```hcl
variable "primary_location"   { default = "southcentralus" }
variable "secondary_location" { default = "northcentralus" }

locals {
  region_short_names = {
    "southcentralus" = "scus"
    "northcentralus" = "ncus"
    "eastus2"        = "eus2"
    "centralus"      = "cus"
    "westus2"        = "wus2"
    "westeurope"     = "weu"
    "northeurope"    = "neu"
    # ... extend as needed
  }
  pri = local.region_short_names[var.primary_location]
  sec = local.region_short_names[var.secondary_location]
}
```

All resource names use `{pri}` / `{sec}` tokens derived from the chosen regions. To deploy to a different region pair, change only `primary_location` and `secondary_location` — everything else auto-derives.

### 1.3 Azure Resources per Region

| Resource | Primary (`{pri}`) | Secondary (`{sec}`) | Notes |
|---|---|---|---|
| Resource Group | `rg-radshow-{env}-{pri}` | `rg-radshow-{env}-{sec}` | CAF naming, region-derived |
| VNet | `vnet-radshow-{env}-{pri}` (10.1.0.0/16) | `vnet-radshow-{env}-{sec}` (10.2.0.0/16) | Peered bidirectionally |
| Front Door | `fd-radshow-{env}` (global) | — | Premium SKU, **active-passive** origin priority (primary=1, secondary=2) |
| WAF Policy | `waf-radshow-{env}` | — | OWASP 3.2 + Bot Manager, Prevention mode |
| APIM | `apim-radshow-{env}-{pri}` | Gateway-only replica in `{sec}` | Premium Classic, multi-region. Config/management plane in primary only (per NFR-13) |
| Function App | `func-radshow-{env}-{pri}` | `func-radshow-{env}-{sec}` | EP1 Elastic Premium on ASP, .NET 8 isolated |
| App Service Plan (Functions) | `asp-radshow-{env}-{pri}-func` | `asp-radshow-{env}-{sec}-func` | EP1, zone redundant where supported |
| Container App Environment | `cae-radshow-{env}-{pri}` | `cae-radshow-{env}-{sec}` | Internal, VNet integrated |
| Container App | `ca-radshow-api-{env}-{pri}` | `ca-radshow-api-{env}-{sec}` | .NET 8 API container, min replicas=1 (warm) |
| Container Instances | `ci-radshow-{env}-{pri}` | `ci-radshow-{env}-{sec}` | Utility/worker containers |
| ACR | `acrradshow{env}` (global) | Geo-replicated to `{sec}` | Single ACR, replicated to both regions |
| SQL MI | `sqlmi-radshow-{env}-{pri}` | `sqlmi-radshow-{env}-{sec}` | GP_G8IM Premium Series, Failover Group `fog-radshow-{env}` |
| Redis | `redis-radshow-{env}-{pri}` | `redis-radshow-{env}-{sec}` | Premium P1, geo-replication link |
| Key Vault | `kv-radshow-{env}-{pri}` | `kv-radshow-{env}-{sec}` | RBAC, purge protection, stores Failover password |
| Storage | `stradshow{env}{pri}` | `stradshow{env}{sec}` | RA-GZRS, `$web` container for SPA hosting |
| Log Analytics | `law-radshow-{env}-{pri}` | — | Centralized workspace |
| App Insights | `appi-radshow-{env}-{pri}` + `appi-radshow-{env}-{sec}` | — | Workspace-based, per region |
| Automation Account | `aa-radshow-{env}-dr` | — | DR failover runbook + webhook |
| Private Endpoints | Per service per region | Per service per region | All PaaS behind PE |
| Private DNS Zones | Linked to both VNets | — | Shared zones |

> **Region capability awareness:** The modules include a `region_capabilities` local that auto-adjusts zone redundancy, storage replication types, and SKU availability based on the selected regions. For example, if a region doesn't support AZ, `zone_redundant` is automatically set to `false`.

### 1.4 Key Architecture Decisions

**Front Door — Active-Passive routing:**
```
Primary origin:   priority = 1, weight = 1000
Secondary origin: priority = 2, weight = 1000
```
Front Door routes all traffic to priority-1 origin. Only when health probes fail on primary does it route to priority-2. This implements active-passive per FR-02.

**APIM Multi-Region (per NFR-13):**
- Deploy APIM in `var.primary_location` as the primary instance (Premium Classic, 1 unit)
- Use `additional_location` block to deploy **gateway-only** to `var.secondary_location`
- During failover: gateway in secondary is already running and can serve traffic
- Important constraint: *no APIM config changes during failover* (management plane stays in primary)
- Terraform:
  ```hcl
  resource "azurerm_api_management" "this" {
    location = var.primary_location
    sku_name = "Premium_1"
    additional_location {
      location = var.secondary_location
      capacity = 1
      zones    = local.secondary_az_supported ? ["1","2","3"] : []
      virtual_network_configuration {
        subnet_id = var.secondary_apim_subnet_id
      }
    }
  }
  ```

**SQL MI Failover Group — Tier 1 tuning (per NFR-05):**
- Grace period: **5 minutes** (down from 60) to meet ≤ 15 min RTO
- Failover policy: `Manual` for Phase 1 (operator-triggered), `Automatic` consideration for Phase 2
- Cross-region async replication provides RPO close to 0 depending on replication lag
- Failover group spans `var.primary_location` → `var.secondary_location` — works with any region pair that supports SQL MI

**Container App Environment:**
- Internal mode, VNet-integrated into `snet-aca` subnet
- Min replicas = 1 in secondary (warm passive — avoids cold start per Section 4.2)
- Ingress = internal only (traffic via APIM)

**ACR Geo-Replication:**
- Single ACR in SCUS, geo-replicated to NCUS
- Both regions pull from local replica — no cross-region pull latency

**Storage Static Website Hosting:**
- Enable `static_website` on storage accounts
- SPA bundle deployed to `$web` container
- Front Door origin group `og-spa` points to both storage blob endpoints (active-passive)

---

## PHASE 2: Lifecycle Controller (`radshow-lic`)

### 2.1 Terragrunt Structure

```
radshow-lic/
├── terragrunt.hcl                    # Root config (remote state, provider)
├── _envcommon/                       # Shared Terragrunt includes
│   ├── resource-group.hcl
│   ├── networking.hcl
│   ├── front-door.hcl
│   ├── apim.hcl
│   ├── function-app.hcl
│   ├── container-apps.hcl
│   ├── container-instances.hcl
│   ├── container-registry.hcl
│   ├── sql-mi.hcl
│   ├── redis.hcl
│   ├── key-vault.hcl
│   ├── storage.hcl
│   ├── monitoring.hcl
│   └── automation.hcl
├── DEV01/                            # DEV environment
│   ├── env.hcl                       # env-specific vars (small SKUs, lower counts)
│   ├── resource-group/terragrunt.hcl
│   ├── networking/terragrunt.hcl
│   ├── ... (one folder per module)
├── STG01/                            # STG (mirrors PRD SKUs)
│   ├── env.hcl
│   └── ...
├── PRD01/                            # PRD (full production)
│   ├── env.hcl
│   └── ...
└── .github/
    └── workflows/
        ├── plan.yml                  # On PR: terragrunt plan
        └── apply.yml                 # On merge: terragrunt apply (with approval gate for PRD)
```

### 2.2 Environment Sizing

| Config | DEV01 | STG01 | PRD01 |
|---|---|---|---|
| Primary region | `var.primary_location` | `var.primary_location` | `var.primary_location` |
| Secondary region | `var.secondary_location` | `var.secondary_location` | `var.secondary_location` |
| APIM SKU | Developer_1 | Premium_1 (single region) | Premium_1 (multi-region) |
| Functions SKU | EP1 | EP1 | EP1 |
| SQL MI vCores | 4 (GP_G8IM) | 4 (GP_G8IM) | 4+ (GP_G8IM) |
| Redis | Standard C1 | Premium P1 | Premium P1 |
| ACA min replicas | 0 | 1 | 1 |
| Secondary region | Deployed but minimal | Full mirror | Full mirror |
| Resource Locks | None | None | CanNotDelete on SQL MI, APIM, KV (per IR-02) |

> Each environment can target different region pairs if needed (e.g., DEV in eastus2/centralus, PRD in southcentralus/northcentralus).

### 2.3 Remote State

- State stored in Azure Storage Account per environment
- State locking via Azure Blob lease
- State files: one per Terragrunt module stack

---

## PHASE 3: Application Components

### 3.1 `radshow-spa` — Vue.js SPA

**Tech**: Vue 3 + Vite + TypeScript

**Pages/Views:**

| View | Description | Requirement |
|---|---|---|
| **Regional Status** | Dashboard showing health of each component per region (Front Door, APIM, Functions, ACA, Storage, KV, Redis, SQL MI, ACR) | FR-03 |
| **Product Inventory** | CRUD table for products (name, description, price, quantity, origin region, last updated region) | FR-04, FR-05 |
| **Failover Control** | Button labeled "Failover" or "Failback" depending on active region, with password prompt modal | FR-06, FR-07, FR-08 |

**Build artifact**: Static JS/CSS bundle → uploaded to Storage `$web` container

**API calls**: All go through Front Door → APIM → backend

### 3.2 `radshow-api` — Backend APIs (.NET 8)

**Two deployment targets from the same codebase:**

| Component | Host | Endpoints |
|---|---|---|
| **Functions App** | Azure Functions (EP1) | `POST/GET/PUT/DELETE /api/products`, `GET /api/status`, `POST /api/failover` |
| **Container App** | ACA | Same endpoints, containerized deployment, demonstrates ACA capability |

**Key API Endpoints:**

```
GET    /api/products            → List all products
GET    /api/products/{id}       → Get product by ID
POST   /api/products            → Create product (sets origin_region + last_updated_region)
PUT    /api/products/{id}       → Update product (auto-sets last_updated_region to current active region)
DELETE /api/products/{id}       → Delete product

GET    /api/status              → Regional Status (health checks all components)
GET    /api/status/{component}  → Individual component health

POST   /api/failover            → Trigger failover/failback
  Body: { "password": "...", "action": "failover|failback" }
  - Validates password against Key Vault (NFR-06, NFR-07)
  - Orchestrates: SQL MI FOG switch → Front Door origin priority update → config flag update
  - Returns: { "success": true, "rto_seconds": N, "new_primary": "region" }

GET    /health                  → Health probe endpoint for Front Door
```

**Failover Orchestration Logic (inside `/api/failover`):**

1. Validate password against Key Vault secret `failover-password`
2. Read current active region from Key Vault secret `active-region` (determines direction: failover vs failback)
3. Trigger SQL MI failover group switch to the target region
4. Wait for completion
5. Update Front Door origin priorities (swap primary/secondary)
6. Update Key Vault secret `active-region` to the new primary region name
7. Return timing/result including `new_primary` region

> The orchestration is region-agnostic — it reads the current and target regions from config, not from hardcoded values. This allows the same code to work for any region pair.

**Data Model (SQL MI):**

```sql
CREATE TABLE Products (
    Id              UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    Name            NVARCHAR(200) NOT NULL,
    Description     NVARCHAR(1000),
    Price           DECIMAL(18,2) NOT NULL,
    QuantityInStock INT NOT NULL DEFAULT 0,
    OriginRegion    NVARCHAR(50) NOT NULL,
    LastUpdatedRegion NVARCHAR(50) NOT NULL,
    CreatedAt       DATETIME2 DEFAULT GETUTCDATE(),
    UpdatedAt       DATETIME2 DEFAULT GETUTCDATE()
);
```

### 3.3 `radshow-apim` — APIOps Configuration

**Follows the [Azure APIOps Toolkit](https://github.com/Azure/APIOps) pattern with GitHub Actions:**

```
radshow-apim/
├── configuration.{env}.yaml         # Per-environment APIM settings
├── apimartifacts/
│   ├── apis/
│   │   ├── radshow-product-api/
│   │   │   ├── apiInformation.json   # API metadata (name, path, display name)
│   │   │   ├── specification.yaml    # OpenAPI 3.0 spec
│   │   │   └── policy.xml            # API-level policy
│   │   └── radshow-status-api/
│   │       ├── apiInformation.json
│   │       ├── specification.yaml
│   │       └── policy.xml
│   ├── policy-fragments/
│   │   ├── cors-policy.xml
│   │   └── auth-policy.xml
│   ├── backends/
│   │   ├── functions-primary.json
│   │   ├── functions-secondary.json
│   │   ├── aca-primary.json
│   │   └── aca-secondary.json
│   ├── named-values/
│   │   └── named-values.json
│   └── products/
│       └── unlimited.json
├── .github/
│   └── workflows/
│       ├── extractor.yml             # Extracts config from dev APIM
│       └── publisher.yml             # Publishes to STG/PRD APIM
└── README.md
```

**APIM Routing Policy** (routes to Functions or ACA based on context):

```xml
<policies>
  <inbound>
    <set-backend-service base-url="https://func-radshow-{env}-{region}.azurewebsites.net/api" />
  </inbound>
</policies>
```

During failover, since APIM gateway is already in both regions and Front Door handles routing, no APIM config change is needed — traffic simply flows to the NCUS gateway which routes to NCUS backends.

### 3.4 `radshow-db` — Database Artifacts

```
radshow-db/
├── migrations/
│   ├── V001__create_products_table.sql
│   ├── V002__seed_sample_data.sql
│   └── V003__add_indexes.sql
├── scripts/
│   └── verify_replication.sql
└── README.md
```

---

## PHASE 4: CI/CD Pipelines

### 4.1 `radshow-spa` CI Pipeline

```yaml
# .github/workflows/ci.yml
trigger: push to main
steps:
  1. npm install
  2. npm run build
  3. npm run test
  4. Upload dist/ bundle to Azure Storage $web (primary)
  5. Upload dist/ bundle to Azure Storage $web (secondary)
  6. Purge Front Door cache
```

### 4.2 `radshow-api` CI Pipeline

```yaml
# .github/workflows/ci.yml
trigger: push to main
steps:
  1. dotnet restore
  2. dotnet build
  3. dotnet test
  4. dotnet publish → zip for Functions deployment
  5. docker build → container image for ACA
  6. docker push to ACR (tagged with commit SHA as immutable identifier)
  7. Output: image digest + functions zip hash
```

### 4.3 `radshow-lic` CD Pipeline

```yaml
# .github/workflows/plan.yml (on PR)
steps:
  1. terragrunt init
  2. terragrunt validate
  3. terragrunt plan → post plan output as PR comment

# .github/workflows/apply.yml (on merge)
steps:
  1. terragrunt init
  2. terragrunt apply -auto-approve
  # For PRD01 branch: requires manual approval gate via GitHub Environment protection rules
```

### 4.4 `radshow-apim` APIOps Pipeline

```yaml
# .github/workflows/publisher.yml
trigger: push to main
steps:
  1. Checkout apimartifacts/
  2. Run APIOps publisher tool
  3. Publish API definitions + policies to DEV APIM
  4. On approval: publish to STG APIM
  5. On approval: publish to PRD APIM
```

---

## PHASE 5: DR Runbooks & Failover Procedures

### 5.1 Scripted Runbooks (per FR-10, Section 11)

```
radshow-def/runbooks/
├── 00-setup-environment.ps1          # Set environment variables (reads primary/secondary from config)
├── 01-check-health.ps1               # Pre-drill health check all components
├── 02-planned-failover.ps1           # Full planned failover primary → secondary
├── 03-unplanned-failover.ps1         # Simulated outage + forced failover
├── 04-planned-failback.ps1           # Controlled failback secondary → primary
├── 05-validate-failover.ps1          # Post-failover validation (CRUD + region check)
├── 06-capture-evidence.ps1           # Export logs, metrics, timestamps as artifacts
└── README.md                         # Step-by-step procedures matching Section 12
```

> All runbooks read region names from `00-setup-environment.ps1` config. Changing the region pair requires updating only that file — no script logic changes.

### 5.2 UI-Based Failover (per FR-06 through FR-08)

The `/api/failover` endpoint in `radshow-api` is the primary mechanism:

1. User clicks "Failover" button in SPA
2. Password prompt modal appears
3. Password sent to API → validated against Key Vault secret
4. Orchestration executes (SQL MI FOG → Front Door → config flags)
5. UI refreshes Regional Status to show new active region

**Fallback mechanism** (per Section 12.3): If primary UI is unreachable, the `/api/failover` endpoint can also be called directly via the secondary region's URL, or the Azure Automation runbook can be triggered via webhook/portal.

---

## PHASE 6: Implementation Order (Sprints)

| Sprint | Deliverable |
|---|---|
| **Sprint 1** | Repo creation + `radshow-def` module scaffolding (all Terraform modules with variables, outputs, empty main.tf) + Terragrunt root config in `radshow-lic` |
| **Sprint 2** | Core infra modules: resource-group, networking, vnet-peering, private-dns, key-vault, storage (with $web), monitoring |
| **Sprint 3** | Compute modules: function-app, container-apps, container-instances, container-registry, app-service-plan |
| **Sprint 4** | Data modules: sql-mi + failover group, redis + geo-replication |
| **Sprint 5** | Ingress modules: front-door (active-passive), apim (Premium Classic multi-region), WAF policy |
| **Sprint 6** | `radshow-api` — Product Inventory CRUD + Regional Status + health endpoints, deployed to Functions + ACA |
| **Sprint 7** | `radshow-spa` — Vue.js SPA (Regional Status, Product Inventory, Failover Control UI) |
| **Sprint 8** | `radshow-apim` — APIOps configuration, API definitions, policies, extractor/publisher pipelines |
| **Sprint 9** | `radshow-db` — Schema migrations, seed data, replication verification |
| **Sprint 10** | Failover orchestration: `/api/failover` endpoint, Automation runbook, password-protected UI control |
| **Sprint 11** | CI/CD pipelines for all repos + Terragrunt CD for DEV01/STG01/PRD01 |
| **Sprint 12** | DR runbooks, evidence capture scripts, end-to-end failover/failback testing, PRD01 resource locks |

---

## Key Constraints & Notes

1. **APIM Premium Classic** is the only SKU that supports multi-region gateway deployment. The secondary region gets gateway-only — no config changes allowed during failover (per NFR-13). This is by design.

2. **Secondary region capability variance**: Some regions may have limited AZ support or SKU availability. The modules include a `region_capabilities` lookup that auto-adjusts `zone_redundant`, storage replication types, and SKU fallbacks based on the selected regions. This is documented as "as equivalent as possible" per Section 4.2. Default pairing is SCUS/NCUS but any supported pair works.

3. **Ephemeral environments** (IR-01): DEV and STG environments can be created/destroyed via `terragrunt destroy` on their branches. PRD has `CanNotDelete` locks on SQL MI, APIM, and Key Vault (per IR-02).

4. **APIOps approach** (per NFR-12): IaC (Terraform) manages the APIM *infrastructure* (instance, networking, SKU). APIOps (GitHub Actions + Azure APIOps Toolkit) manages the *API configuration* (API definitions, policies, products, named values). This is the recommended "layered approach" per Microsoft Well-Architected guidance.

5. **Immutable artifact identifiers** (per PR-02): `radshow-def` references container images by **digest** (e.g., `acrradshowprd.azurecr.io/api@sha256:abc123`), not by tag. Function zip packages are referenced by hash.
