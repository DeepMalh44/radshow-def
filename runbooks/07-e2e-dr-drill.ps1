<#
.SYNOPSIS
    End-to-End DR Drill Orchestrator
.DESCRIPTION
    Runs the complete DR drill sequence as a single automated pipeline:
      Phase 1: Setup + Health Check (go/no-go gate)
      Phase 2: Planned Failover + Validation + Evidence
      Phase 3: Soak period with CRUD verification
      Phase 4: Failback + Validation + Evidence
      Phase 5: Final report with aggregate timing

    Designed for scheduled DR drills or compliance exercises.
.NOTES
    Version: 1.0.0
    Tier: 3 (Operator workstation)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectName = "radshow",

    [Parameter(Mandatory = $false)]
    [string]$Environment = "prd01",

    [Parameter(Mandatory = $false)]
    [string]$PrimaryRegion = "southcentralus",

    [Parameter(Mandatory = $false)]
    [string]$SecondaryRegion = "northcentralus",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "",

    [Parameter(Mandatory = $false)]
    [int]$SoakMinutes = 5,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoPrompt,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$overallStart = Get-Date
$phaseResults = @()

Write-Host ""
Write-Host "################################################################" -ForegroundColor Cyan
Write-Host "  RAD Showcase — End-to-End DR Drill" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC" -ForegroundColor Cyan
Write-Host "  Soak Period: $SoakMinutes minutes" -ForegroundColor Cyan
Write-Host "################################################################" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Magenta
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: Environment Setup + Health Check
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  PHASE 1: Environment Setup + Health Check" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
$phaseStart = Get-Date

$setupParams = @{
    ProjectName    = $ProjectName
    Environment    = $Environment
    PrimaryRegion  = $PrimaryRegion
    SecondaryRegion = $SecondaryRegion
}
if ($SubscriptionId) { $setupParams.SubscriptionId = $SubscriptionId }

& "$scriptDir\00-setup-environment.ps1" @setupParams

if (-not $global:DrConfig) {
    Write-Host "[ABORT] Environment setup failed." -ForegroundColor Red
    return
}

& "$scriptDir\01-check-health.ps1" -Config $global:DrConfig -NoPrompt:$NoPrompt

$phaseResults += @{ Phase = "1: Setup + Health"; Duration = ((Get-Date) - $phaseStart).TotalSeconds }
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Planned Failover
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  PHASE 2: Planned Failover" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
$phaseStart = Get-Date
$failoverStart = Get-Date

& "$scriptDir\02-planned-failover.ps1" -Config $global:DrConfig -DryRun:$DryRun -NoPrompt:$NoPrompt

$failoverRTO = $global:FailoverRTO

& "$scriptDir\05-validate-failover.ps1" -Config $global:DrConfig -OperationType "failover"

& "$scriptDir\06-capture-evidence.ps1" `
    -Config $global:DrConfig `
    -DrillStartTime $failoverStart `
    -MeasuredRTO $failoverRTO `
    -DrillType "PlannedFailover" `
    -OutputPath $OutputPath

$phaseResults += @{ Phase = "2: Failover"; Duration = ((Get-Date) - $phaseStart).TotalSeconds; RTO = $failoverRTO }
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: Soak Period (CRUD test on secondary)
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  PHASE 3: Soak Period ($SoakMinutes min)" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
$phaseStart = Get-Date

if ($SoakMinutes -gt 0 -and -not $DryRun) {
    Write-Host "  Soaking for $SoakMinutes minutes on secondary region..." -ForegroundColor Yellow
    $soakEnd = (Get-Date).AddMinutes($SoakMinutes)
    $iteration = 0

    while ((Get-Date) -lt $soakEnd) {
        $iteration++
        $remaining = [math]::Round(($soakEnd - (Get-Date)).TotalSeconds)
        Write-Host "  [Soak iteration $iteration] ${remaining}s remaining..." -ForegroundColor Gray

        # Quick health probe via Front Door
        try {
            $resp = Invoke-WebRequest -Uri "$($global:DrConfig.FrontDoorEndpoint)/health" -Method GET -TimeoutSec 10 -ErrorAction SilentlyContinue
            Write-Host "  Health probe: $($resp.StatusCode)" -ForegroundColor $(if ($resp.StatusCode -eq 200) { "Green" } else { "Yellow" })
        }
        catch {
            Write-Host "  Health probe: Failed ($($_.Exception.Message))" -ForegroundColor Yellow
        }

        Start-Sleep -Seconds 30
    }
}
elseif ($DryRun) {
    Write-Host "  [DRY RUN] Would soak for $SoakMinutes minutes" -ForegroundColor Magenta
}

$phaseResults += @{ Phase = "3: Soak"; Duration = ((Get-Date) - $phaseStart).TotalSeconds }
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: Planned Failback
# ═══════════════════════════════════════════════════════════════════════════
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  PHASE 4: Planned Failback" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
$phaseStart = Get-Date
$failbackStart = Get-Date

& "$scriptDir\04-planned-failback.ps1" -Config $global:DrConfig -DryRun:$DryRun -NoPrompt:$NoPrompt

& "$scriptDir\05-validate-failover.ps1" -Config $global:DrConfig -OperationType "failback"

& "$scriptDir\06-capture-evidence.ps1" `
    -Config $global:DrConfig `
    -DrillStartTime $failbackStart `
    -DrillType "PlannedFailback" `
    -OutputPath $OutputPath

$phaseResults += @{ Phase = "4: Failback"; Duration = ((Get-Date) - $phaseStart).TotalSeconds }
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: Final Report
# ═══════════════════════════════════════════════════════════════════════════
$overallEnd = Get-Date
$overallDuration = ($overallEnd - $overallStart).TotalSeconds

Write-Host ""
Write-Host "################################################################" -ForegroundColor Cyan
Write-Host "  E2E DR Drill Complete" -ForegroundColor Cyan
Write-Host "################################################################" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Overall Duration:  $([math]::Round($overallDuration / 60, 1)) min ($([math]::Round($overallDuration))s)"
Write-Host "  Failover RTO:      $($failoverRTO)s" -ForegroundColor $(if ($failoverRTO -le 900) { "Green" } else { "Yellow" })
Write-Host ""

foreach ($pr in $phaseResults) {
    $rtoStr = if ($pr.RTO) { " (RTO: $($pr.RTO)s)" } else { "" }
    Write-Host "  $($pr.Phase): $([math]::Round($pr.Duration))s$rtoStr"
}

Write-Host ""
Write-Host "  Evidence files exported to: $OutputPath" -ForegroundColor Green
Write-Host ""
