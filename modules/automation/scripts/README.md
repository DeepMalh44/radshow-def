# RAD Showcase - DR Automation Runbook Scripts

Modular PowerShell scripts for Disaster Recovery drill execution and automation.

## Scripts

| Script | Purpose |
|--------|---------|
| `00-Setup-Environment.ps1` | Configuration & Managed Identity authentication |
| `01-Check-Health.ps1` | Pre-drill health check (SQL MI FOG, Redis, Front Door, KV) |
| `02-Planned-Failover.ps1` | Graceful failover with zero data loss |
| `03-Unplanned-Failover.ps1` | Forced failover simulating real outage (AllowDataLoss) |
| `04-Planned-Failback.ps1` | Return to primary region |
| `05-Validate-Failover.ps1` | Post-operation validation |
| `06-Capture-Evidence.ps1` | Export logs, metrics, timestamps for compliance |
| `Invoke-DRFailover.ps1` | Azure Automation Runbook (webhook/alert-triggered) |

## Usage

### Interactive DR Drill (step-by-step)

```powershell
# 1. Setup
.\00-Setup-Environment.ps1 -ProjectName "radshow" -Environment "prd01"

# 2. Pre-drill health check
.\01-Check-Health.ps1

# 3a. Planned failover (zero data loss)
.\02-Planned-Failover.ps1

# 3b. OR unplanned failover (simulated outage)
.\03-Unplanned-Failover.ps1

# 4. Validate
.\05-Validate-Failover.ps1 -OperationType "failover"

# 5. Capture evidence
.\06-Capture-Evidence.ps1 -DrillStartTime $drillStart -MeasuredRTO $global:FailoverRTO

# 6. Failback
.\04-Planned-Failback.ps1

# 7. Validate failback
.\05-Validate-Failover.ps1 -OperationType "failback"
```

### Dry Run (no changes)

```powershell
.\00-Setup-Environment.ps1
.\02-Planned-Failover.ps1 -DryRun
```

### Azure Automation Runbook

The `Invoke-DRFailover.ps1` script is deployed as an Azure Automation Runbook and can be:
- Triggered by Azure Monitor alert webhooks
- Invoked manually from the portal
- Called via the `/api/failover` endpoint in the RAD Showcase API

## Prerequisites

- Az.Accounts, Az.Sql, Az.RedisCache, Az.Cdn, Az.KeyVault PowerShell modules
- Automation Account with System Assigned Managed Identity
- RBAC roles: SQL MI Contributor, Redis Contributor, CDN Profile Contributor, Key Vault Secrets Officer
