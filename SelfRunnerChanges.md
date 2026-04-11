# Enterprise Private Networking & Self-Hosted Runners — Full Plan

## Current State Summary

| Resource | Current Access | Needs Change? |
|----------|---------------|---------------|
| **Front Door** | Public | No — intentionally the only public entry point |
| **Application Gateway** | Public IP (locked to FD via NSG + `X-Azure-FDID`) | **Yes** — can use FD Private Link origin |
| **Function App** | Public HTTPS | **Yes** — disable public access |
| **Storage Account** | Public (for SPA `$web` + FD) | **Yes** — lock down to private + FD Private Link |
| **Redis Cache** | Public (TLS only) | **Yes** — VNet inject + disable public |
| **Key Vault** | Already private | No |
| **APIM** | Already internal/VNet | No |
| **SQL MI** | Already VNet-injected | No |
| **Container Registry** | Already private | No — but runners need PE access |
| **Container Apps** | Already internal | No |
| **Monitoring (LA/AppInsights)** | Public (Azure defaults) | No — acceptable as-is |

---

## Part 1: Self-Hosted GitHub Runners in Azure

### 1A. Provision Runner Infrastructure

Create a new Terraform module (`modules/github-runners` or separate repo) deploying:

| Resource | Purpose |
|----------|---------|
| **Virtual Machine Scale Set (VMSS)** or **Container App Jobs** | Runner compute (Linux, `Standard_D4s_v5` or similar) |
| **VNet subnet** | Dedicated `/26` or `/25` subnet in each region's VNet (add to `modules/networking`) |
| **NSG** | Allow outbound to `github.com`, `*.actions.githubusercontent.com`, `*.blob.core.windows.net` on 443 |
| **NAT Gateway** (or Azure Firewall) | Stable outbound IP for GitHub communication |
| **Managed Identity** | System-assigned MI for Azure auth (replaces OIDC federated credentials) |

> **Recommended approach**: Use [GitHub's official Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) on an AKS cluster, or use VMSS-based ephemeral runners with the [github/actions-runner](https://github.com/actions/runner) agent.

### 1B. Runner Registration

```bash
# Per-org runner group (enterprise) or per-repo runners
# Register via GitHub org Settings → Actions → Runners → New self-hosted runner
# Or use the config.sh script with a registration token
```

Each environment (DEV01/STG01/PRD01) should have its own runner group with labels like `self-hosted`, `linux`, `azure-{env}`.

### 1C. Runner Network Requirements (Outbound)

Runners need outbound HTTPS (443) to:

| Destination | Purpose |
|-------------|---------|
| `github.com` / `api.github.com` | Repo clone, API calls |
| `*.actions.githubusercontent.com` | Action downloads |
| `*.blob.core.windows.net` | Action caches, artifacts |
| `*.pkg.github.com` / `ghcr.io` | Container image pulls (if using GitHub packages) |
| `login.microsoftonline.com` | Entra auth (if still using OIDC) |
| `management.azure.com` | ARM API calls (`az` CLI) |

If using Azure Firewall, create application rules for these FQDNs.

---

## Part 2: Workflow File Changes (All App Repos)

### 2A. Update `runs-on` in Every Workflow

**Affected repos**: `radshow-lic`, `radshow-api`, `radshow-spa`, `radshow-db`, `radshow-apim`, `radshow-def`

| Current | Change to |
|---------|-----------|
| `runs-on: ubuntu-latest` | `runs-on: [self-hosted, linux, azure-{env}]` |

If workflows use a matrix per environment, the `runs-on` label should match the environment's runner group.

### 2B. Authentication Change (Optional but Recommended)

| Current | Enterprise alternative |
|---------|----------------------|
| OIDC federated credentials (app registration per env) | **Managed Identity** on the runner VMSS — no secrets, no app registrations needed |

If runners use system-assigned MI, replace `azure/login@v2` OIDC config with MI-based login:

```yaml
- uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}  # MI client ID
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    # No federated token needed — MI handles auth automatically
```

Or use `az login --identity` directly in script steps.

### 2C. Runner Tool Requirements

Ensure runner images have pre-installed:
- `az` CLI, `terraform`, `terragrunt`, `docker`, `node`, `dotnet` SDK 8+, `sqlcmd`
- Or use a custom runner image with all tools baked in

---

## Part 3: Lock Down Public Endpoints (Terraform Module Changes)

### 3A. Function App — `modules/function-app` (`radshow-def`)

| Change | Detail |
|--------|--------|
| Set `public_network_access_enabled = false` | Block all public access |
| Add `ip_restriction` for runner subnet | Allow CI/CD image push from runner VNet |
| Ensure `vnet_integration_subnet_id` is set | Route all outbound via VNet |
| Set `vnet_route_all_enabled = true` | Force all outbound through VNet (needed for PE to ACR, KV, SQL) |
| Create Private Endpoint | `subresource_names = ["sites"]` — needed for AppGW to reach func app backend |

> **Impact**: AppGW backend pool must switch from Function App public FQDN to private IP/FQDN via PE.

### 3B. Storage Account — `modules/storage` (`radshow-def`)

| Change | Detail |
|--------|--------|
| Set `public_network_access_enabled = false` | Block all public access |
| Create Private Endpoint for blob | `subresource_names = ["blob"]` |
| Create Private Endpoint for web | `subresource_names = ["web"]` — for SPA static website |
| Add runner subnet to network rules | `virtual_network_subnet_ids` — allow CI/CD uploads |

> **Impact on SPA**: Front Door must use **Private Link origin** to reach Storage static website. This requires FD Premium (already in use) with `private_link` block on the origin.

### 3C. Redis Cache — `modules/redis` (`radshow-def`)

| Change | Detail |
|--------|--------|
| Set `public_network_access_enabled = false` | Block all public access |
| Ensure `subnet_id` is set (VNet injection) | Already supported by module variable |
| Create Private Endpoint | `subresource_names = ["redisCache"]` |

### 3D. Application Gateway — `modules/application-gateway` (`radshow-def`)

| Change | Detail |
|--------|--------|
| Keep public IP + tighten NSG | FD doesn't support PE to AppGW — keep public IP but restrict NSG to `AzureFrontDoor.Backend` only (already done) |

> **Note**: Front Door can use Private Link to App Service/Storage origins directly, but **not to Application Gateway** (as of current Azure support). AppGW public IP + NSG lockdown remains the recommended pattern. The NSG + `X-Azure-FDID` header validation already prevents direct access.

### 3E. Container Registry — `modules/container-registry` (`radshow-def`)

Already private (`public_network_access_enabled = false`). Additional changes:

| Change | Detail |
|--------|--------|
| Create PE for runner subnet | Runners need PE access to push Docker images |
| Ensure `AzureServices` bypass stays | Function App MI pulls via trusted Azure services |

### 3F. Front Door Origins — `modules/front-door` (`radshow-def`)

| Change | Detail |
|--------|--------|
| Enable **Private Link origins** for Storage SPA | FD connects to Storage via PE instead of public endpoint |
| Keep AppGW origin as-is | FD → AppGW uses public IP + NSG lockdown (Azure doesn't support FD PE to AppGW) |

The `origins` variable already supports `private_link` blocks (confirmed in module). Callers in `radshow-lic` need to pass Private Link config.

---

## Part 4: Networking Changes — `modules/networking` (`radshow-def`) + `radshow-lic`

### 4A. Add Runner Subnet

Add a new subnet to each region's VNet:

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `snet-runners` | `/26` (64 IPs) or `/25` (128 IPs) | Self-hosted GitHub runners |

### 4B. Add NAT Gateway or Azure Firewall

Runners need outbound internet for GitHub API. Options:

| Option | Pros | Cons |
|--------|------|------|
| **NAT Gateway** on runner subnet | Simple, cheap, stable outbound IP | No FQDN filtering |
| **Azure Firewall** (hub VNet) | Full FQDN filtering, logging | More expensive, hub-spoke needed |
| **Azure Firewall Basic** | Lower cost + FQDN filtering | Feature limitations |

### 4C. Private DNS Zones

Add/verify these private DNS zones linked to both VNets:

| Zone | For |
|------|-----|
| `privatelink.blob.core.windows.net` | Storage PE |
| `privatelink.web.core.windows.net` | Storage static website PE |
| `privatelink.azurecr.io` | ACR PE |
| `privatelink.vaultcore.azure.net` | Key Vault PE (may already exist) |
| `privatelink.redis.cache.windows.net` | Redis PE |
| `privatelink.azurewebsites.net` | Function App PE |

---

## Part 5: Changes Per Repo Summary

| Repo | Changes Required |
|------|-----------------|
| **radshow-def** | Update modules: `function-app` (disable public, add PE support), `storage` (disable public), `redis` (disable public), `front-door` (Private Link origins for storage), `networking` (add runner subnet). Optionally add `modules/github-runners`. |
| **radshow-lic** | Update Terragrunt configs: pass `public_network_access_enabled = false` to function-app/storage/redis, add PE deployments for all services, add Private Link config to FD origins, add runner subnet CIDR, add private DNS zones. |
| **radshow-api** | Change `runs-on` to self-hosted runner labels. Update `azure/login` if switching to MI. |
| **radshow-spa** | Change `runs-on` to self-hosted runner labels. Storage upload must work via PE (runner on VNet). |
| **radshow-db** | Change `runs-on` to self-hosted runner labels. SQL MI access already VNet-only — runner on same VNet can reach it. |
| **radshow-apim** | Change `runs-on` to self-hosted runner labels. APIM is internal — runner on same VNet can reach management API. |
| **radshow-def** | Change `runs-on` in `validate.yml` (no Azure access needed, but consistency). |

---

## Part 6: Implementation Order

```text
Phase 1 — Runner Infrastructure
  1. Add runner subnet to modules/networking
  2. Deploy runner VMSS or ARC in both regions
  3. Register runners with GitHub org
  4. Test basic workflow on self-hosted runner

Phase 2 — Workflow Migration
  5. Update all workflow files: runs-on → self-hosted labels
  6. Update azure/login steps if switching to MI
  7. Validate all pipelines pass on self-hosted runners

Phase 3 — Private Endpoints & DNS
  8. Create private DNS zones (all zones listed above)
  9. Deploy PEs for: ACR, Storage (blob+web), Function App, Redis
  10. Verify DNS resolution from runner subnet to all PEs

Phase 4 — Lock Down Public Access
  11. Disable public access on Function App
  12. Disable public access on Storage
  13. Disable public access on Redis
  14. Enable FD Private Link origin for Storage SPA

Phase 5 — Validation
  15. Verify FD → AppGW → APIM → Function App flow works
  16. Verify FD → AppGW → Storage SPA flow works (via FD Private Link)
  17. Verify CI/CD pipelines: build, push ACR, deploy Function App, upload SPA
  18. Run DR drill to confirm failover works with private endpoints
  19. Penetration test: confirm no public access to locked-down resources
```

> **Key risk**: Phase 4 (lock down) should only happen **after** Phase 3 (PEs) is verified. Locking down before PEs are working will break the application.
