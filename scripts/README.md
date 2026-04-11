# RAD Showcase — Bootstrap Script

Automates the **full setup** of a RAD Showcase environment from scratch — forks repos, configures files, provisions Azure infrastructure, sets GitHub secrets, triggers CI/CD pipelines, and verifies health.

## Prerequisites

| Tool | Minimum Version | Install |
|------|----------------|---------|
| PowerShell | 7.0+ | `winget install Microsoft.PowerShell` |
| Azure CLI | Latest | `winget install Microsoft.AzureCLI` |
| GitHub CLI | Latest | `winget install GitHub.cli` |
| Terraform | 1.5+ | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| Terragrunt | 1.0+ | [terragrunt.gruntwork.io](https://terragrunt.gruntwork.io/docs/getting-started/install/) |
| Docker | Latest | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Git | Latest | `winget install Git.Git` |

**Before running**, log in to both Azure and GitHub:

```powershell
az login
gh auth login
```

## Quick Start

```powershell
# Full setup — you'll be prompted for all values interactively
.\bootstrap-environment.ps1
```

That's it. The script walks you through everything.

## Parameters

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `-Phase` | `All`, `Prereqs`, `ForkClone`, `Configure`, `TFState`, `OIDC`, `RunnerInfra`, `GitHubSetup`, `Infra`, `PostInfra`, `Deploy`, `PostDeploy`, `Verify` | `All` | Run a specific phase or all phases |
| `-RunnerMode` | `GitHubHosted`, `SelfHosted` | `GitHubHosted` | Public GitHub runners (OIDC) or Azure VMSS runners (Managed Identity) |
| `-DryRun` | switch | off | Preview what would happen without making changes |

## Examples

### Full setup with GitHub-hosted runners (default)

```powershell
.\bootstrap-environment.ps1
```

Uses public GitHub runners with OIDC federated credentials for Azure authentication.

### Full setup with self-hosted runners

```powershell
.\bootstrap-environment.ps1 -RunnerMode SelfHosted
```

Provisions VMSS-based runners in your Azure VNets with Managed Identity — no secrets leave the network.

### Dry run (preview only)

```powershell
.\bootstrap-environment.ps1 -DryRun
```

Shows what would be created/configured without actually doing it.

### Resume from a specific phase

```powershell
# Infrastructure took too long and you disconnected? Resume from PostInfra:
.\bootstrap-environment.ps1 -Phase PostInfra

# Just need to re-trigger pipelines?
.\bootstrap-environment.ps1 -Phase Deploy

# Only set up the OIDC service principal:
.\bootstrap-environment.ps1 -Phase OIDC
```

### Self-hosted runner infrastructure only

```powershell
.\bootstrap-environment.ps1 -Phase RunnerInfra -RunnerMode SelfHosted
```

## What It Does (Phase by Phase)

| # | Phase | What Happens | Duration |
|---|-------|-------------|----------|
| 1 | **Prereqs** | Validates all tools are installed and you're logged in | ~10 sec |
| 2 | **ForkClone** | Forks 6 repos to your GitHub org, clones them locally | ~2 min |
| 3 | **Configure** | Updates `env.hcl`, module sources, APIM config, zone redundancy flags | ~30 sec |
| 4 | **TFState** | Creates resource group + storage account for Terraform state | ~1 min |
| 5a | **OIDC** *(GitHubHosted)* | Creates App Registration, Service Principal, 5 federated creds, 3 RBAC roles | ~2 min |
| 5b | **RunnerInfra** *(SelfHosted)* | Creates VMSS runners, NSG, NAT Gateway, MI, RBAC, installs runner agent | ~10 min |
| 6 | **GitHubSetup** | Creates GitHub environments, sets all secrets on all repos | ~2 min |
| 7 | **Infra** | Runs `terragrunt apply --all` (SQL MI alone takes 2-6 hours) | **2-6 hrs** |
| 8 | **PostInfra** | Reads FOG listener FQDN, sets `SQL_MI_FQDN` secret | ~1 min |
| 9 | **Deploy** | Enables Actions, pushes to trigger pipelines: db → api → apim → spa | ~20 min |
| 10 | **PostDeploy** | Seeds Key Vault secrets, RBAC upgrades, CAE DNS zones | ~5 min |
| 11 | **Verify** | Tests Front Door routes and backend health | ~1 min |

## What You'll Be Prompted For

The script interactively asks for these values (with sensible defaults where possible):

- **GitHub org name** — your org where repos will be forked
- **Environment** — `DEV01`, `STG01`, or `PRD01`
- **Azure Subscription ID** and **Tenant ID**
- **Primary region** / **Secondary region** (e.g. `swedencentral` / `germanywestcentral`)
- **Region short codes** (e.g. `swc` / `gwc`)
- **Entra admin group Object ID** — for SQL MI AAD admin
- **TF state storage account name**
- **DR failover password** — entered securely (masked)
- **Zone redundancy per region** — independently for primary and secondary (not all regions support AZs)
- **Runner VM size**, **subnet CIDR**, **instance count** — SelfHosted mode only

## Runner Modes Explained

### GitHubHosted (default)

```
GitHub Actions (public runner) --OIDC--> Azure AD --federated credential--> Azure resources
```

- Creates an App Registration with federated credentials for each repo
- No secrets stored — uses OIDC token exchange
- Simpler setup, works out of the box

### SelfHosted

```
VMSS Runner (in your VNet) --Managed Identity--> Azure resources directly
```

- Provisions Ubuntu VMSS in each region's VNet with system-assigned MI
- NAT Gateway for stable outbound IPs
- All traffic stays within your network
- No OIDC credentials needed — MI handles authentication
- Better for enterprise environments with network restrictions

## Zone Redundancy

The script asks **per-region** whether to enable availability zone redundancy:

```
--- Availability Zone Redundancy ---
Not all Azure regions support availability zones.
You can enable zone redundancy independently for each region.

Enable zone redundancy for PRIMARY region (southcentralus)?  (Y/n): Y
Enable zone redundancy for SECONDARY region (northcentralus)? (Y/n): n
  Primary (southcentralus): MULTI-ZONE (zones 1, 2, 3)
  Secondary (northcentralus): SINGLE-ZONE
```

This sets the appropriate flags on each resource's Terragrunt config:

| Resource | Variable | Multi-zone value | Single-zone value |
|----------|----------|-----------------|------------------|
| Function App | `zone_redundant` | `true` | `false` |
| App Service | `zone_redundant` | `true` | `false` |
| Container Apps | `zone_redundancy_enabled` | `true` | `false` |
| SQL MI | `zone_redundant` | `true` | `false` |
| Redis | `zones` | `["1","2","3"]` | `[]` |
| ACR | `zone_redundancy_enabled` | `true` | `false` |
| APIM | `zones` | `["1","2","3"]` | `[]` |

Primary and secondary regions are configured **independently** — perfect for cases like `southcentralus` (supports AZs) paired with `northcentralus` (no AZ support).

## Resumability

Every phase is **idempotent** — it checks if work is already done before acting. If the script fails or you disconnect:

1. Note which phase failed (printed in the error message)
2. Re-run with `-Phase <FailedPhase>` to resume

```powershell
# Example: Infra phase timed out
.\bootstrap-environment.ps1 -Phase Infra
```

## Logging

The script creates a timestamped log file in the current directory:

```
bootstrap-all-20260411-143022.log
```

## Related Docs

- [HANDOVER.md](../HANDOVER.md) — Full architecture, design decisions, and manual steps this script automates
- [SelfRunnerChanges.md](../SelfRunnerChanges.md) — Detailed plan for private networking and self-hosted runners
- [RAD_SHOWCASE_OPERATIONS_GUIDE.md](../RAD_SHOWCASE_OPERATIONS_GUIDE.md) — Day-2 operations guide
