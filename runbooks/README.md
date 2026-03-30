# RAD Showcase - Operator DR Drill Runbooks

Standalone PowerShell scripts for interactive DR drill execution from an operator workstation.
These are **Tier 3** scripts — they run from any workstation with Azure access and have **no region dependency**.

> **Distinction from automation module scripts**: The scripts in `modules/automation/scripts/` are
> headless runbooks deployed into Azure Automation Accounts (Tier 2). These `runbooks/` scripts
> are the interactive operator equivalents with colored output, confirmation prompts, and CRUD tests.

## DR Execution Resilience Tiers

| Tier | Mechanism | Region Dependency |
|------|-----------|-------------------|
| **1** | SPA UI → `/api/failover` endpoint | Hits secondary via Front Door if primary down |
| **2** | Azure Automation webhook (dual-region AA) | Both regions have AA — alert fires to whichever is up |
| **3** | Operator runs these `runbooks/` scripts | **None** — runs from any workstation with Azure ARM access |

## Scripts

| Script | Purpose |
|--------|---------|
| `00-setup-environment.ps1` | Interactive auth + config (supports `az login` and service principal) |
| `01-check-health.ps1` | Pre-drill health check with go/no-go gate |
| `02-planned-failover.ps1` | Graceful failover with operator confirmations at each step |
| `03-unplanned-failover.ps1` | Forced failover with double-confirm danger gate (AllowDataLoss) |
| `04-planned-failback.ps1` | Return to primary region with confirmations |
| `05-validate-failover.ps1` | Post-operation validation + E2E CRUD test via Front Door |
| `06-capture-evidence.ps1` | Export JSON evidence + Markdown report to local disk |
| `07-e2e-dr-drill.ps1` | Full E2E orchestrator: Setup→Health→Failover→Soak→Failback→Report |

## Quick Start

### Full E2E Drill (automated)

```powershell
.\07-e2e-dr-drill.ps1 -Environment "prd01" -SoakMinutes 5 -NoPrompt
```

### Full E2E Drill (dry run)

```powershell
.\07-e2e-dr-drill.ps1 -Environment "prd01" -DryRun
```

### Step-by-Step Drill (interactive)

```powershell
# 1. Setup environment + authenticate
.\00-setup-environment.ps1 -ProjectName "radshow" -Environment "prd01"

# 2. Pre-drill health check (operator go/no-go)
.\01-check-health.ps1

# 3a. Planned failover (zero data loss, step confirmations)
.\02-planned-failover.ps1

# 3b. OR unplanned failover (forced, double confirm required)
.\03-unplanned-failover.ps1

# 4. Validate failover + CRUD test
.\05-validate-failover.ps1 -OperationType "failover"

# 5. Capture evidence
.\06-capture-evidence.ps1 -DrillStartTime $global:FailoverStartTime -MeasuredRTO $global:FailoverRTO

# 6. Failback to primary
.\04-planned-failback.ps1

# 7. Validate failback
.\05-validate-failover.ps1 -OperationType "failback"

# 8. Capture failback evidence
.\06-capture-evidence.ps1 -DrillStartTime $global:FailbackStartTime -DrillType "PlannedFailback"
```

### Custom Region Pair

```powershell
.\00-setup-environment.ps1 -PrimaryRegion "eastus2" -SecondaryRegion "centralus" -Environment "dev01"
```

### Service Principal Authentication

```powershell
.\00-setup-environment.ps1 -ServicePrincipal -SubscriptionId "your-sub-id"
```

## Prerequisites

- **PowerShell 7+** with Az PowerShell module (`Install-Module Az`)
- **RBAC Roles** on the target subscription:
  - `Contributor` on resource groups (for Front Door origin updates, Key Vault writes)
  - `SQL Managed Instance Contributor` (for FOG failover)
  - `Key Vault Secrets Officer` (for active-region secret)
  - `Reader` (for health checks and evidence capture)
- **Network access** to Azure Resource Manager APIs (ARM) — no VPN/PE required for these scripts
- This is the key advantage of Tier 3: scripts work from any internet-connected workstation

## Dual Automation Account Architecture

These scripts complement the dual-AA architecture for maximum failover resilience:

```
                    ┌─────────────────────┐
                    │  Azure Monitor       │
                    │  Alert Rule          │
                    └──────┬──────────────┘
                           │ fires to action group
                    ┌──────▼──────────────┐
                    │  Action Group        │
                    │  (dual-AA webhooks)  │
                    └──┬──────────────┬───┘
                       │              │
            ┌──────────▼──┐   ┌──────▼──────────┐
            │ AA Primary   │   │ AA Secondary     │
            │ (region-pri) │   │ (region-sec)     │
            │ Invoke-DR... │   │ Invoke-DR...     │
            └──────────────┘   └─────────────────┘
                                        │
                    If primary region is down,
                    secondary AA executes failover
```

## Escalation Path

1. **Normal**: Use SPA UI failover button (Tier 1)
2. **UI unavailable**: Azure Automation webhook triggers automatically (Tier 2)
3. **Automation unavailable**: Operator runs these scripts from workstation (Tier 3)
4. **Azure Portal**: Manual failover via Azure Portal as last resort
