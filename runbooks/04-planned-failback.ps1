<#
.SYNOPSIS
    Planned Failback - Interactive return to primary region
.DESCRIPTION
    Reverses a previous failover, restoring the primary region as active:
    1. SQL MI FOG switch back to primary
    2. Wait for replication sync
    3. Restore Front Door origin priorities (primary=1, secondary=2)
    4. Restore Key Vault active-region in both vaults
.NOTES
    Version: 1.0.0
    Tier: 3 (Operator workstation)
    Requires: 00-setup-environment.ps1 executed first
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [hashtable]$Config = $global:DrConfig,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run .\00-setup-environment.ps1 first."
    throw
}

$drillStart = Get-Date
$stepResults = @()

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  RAD Showcase - PLANNED FAILBACK" -ForegroundColor Cyan
Write-Host "  Restoring: $($Config.PrimaryRegion) ($($Config.PrimaryRegionShort))" -ForegroundColor Cyan
Write-Host "  Started:   $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Magenta
    Write-Host ""
}

function Confirm-Step {
    param([string]$StepName)
    if (-not $NoPrompt -and -not $DryRun) {
        $answer = Read-Host "  Execute '$StepName'? [Y/N]"
        if ($answer -ne "Y") {
            Write-Host "  Step skipped by operator." -ForegroundColor Yellow
            return $false
        }
    }
    return $true
}

# ── Step 1: SQL MI Failback to Primary ──────────────────────────────────
Write-Host "[STEP 1/4] SQL MI Failback to Primary Region" -ForegroundColor Yellow
$stepStart = Get-Date

try {
    $targetRG = $Config.PrimaryResourceGroup
    $targetLocation = $Config.PrimaryRegion

    Write-Host "  Initiating failback to $targetLocation..."

    if (-not (Confirm-Step "SQL MI Failback")) {
        $stepResults += @{ Step = "SQL MI Failback"; Status = "Skipped"; Duration = 0; Detail = "Operator skipped" }
    }
    else {
        if (-not $DryRun) {
            Switch-AzSqlDatabaseInstanceFailoverGroup `
                -ResourceGroupName $targetRG `
                -Location $targetLocation `
                -Name $Config.SqlMiFailoverGroupName `
                -ErrorAction Stop | Out-Null

            Write-Host "  [OK] Failback initiated" -ForegroundColor Green
        }
        else {
            Write-Host "  [DRY RUN] Would failback to $targetLocation" -ForegroundColor Magenta
        }

        $stepResults += @{
            Step     = "SQL MI Failback"
            Status   = "Success"
            Duration = ((Get-Date) - $stepStart).TotalSeconds
            Detail   = "Failback to $targetLocation"
        }
    }
}
catch {
    $stepResults += @{
        Step     = "SQL MI Failback"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Host "  [FAILED] $($_.Exception.Message)" -ForegroundColor Red
    throw
}

Write-Host "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Host ""

# ── Step 2: Wait for Replication Sync ───────────────────────────────────
Write-Host "[STEP 2/4] Waiting for replication sync..." -ForegroundColor Yellow
$stepStart = Get-Date

if (-not $DryRun) {
    $maxWait = 300
    $elapsed = 0
    $interval = 15
    $synced = $false

    do {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        try {
            $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
                -ResourceGroupName $Config.PrimaryResourceGroup `
                -Location $Config.PrimaryRegion `
                -Name $Config.SqlMiFailoverGroupName `
                -ErrorAction Stop

            Write-Host "  [$elapsed s] Role=$($fog.ReplicationRole)"

            if ($fog.ReplicationRole -eq "Primary") {
                Write-Host "  [OK] Primary region restored as Primary role" -ForegroundColor Green
                $synced = $true
                break
            }
        }
        catch {
            Write-Host "  [$elapsed s] Check failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } while ($elapsed -lt $maxWait)

    if (-not $synced) {
        Write-Host "  [WARN] Sync timed out after $maxWait seconds" -ForegroundColor Yellow
    }
}
else {
    $synced = $true
    Write-Host "  [DRY RUN] Would wait for sync" -ForegroundColor Magenta
}

$stepResults += @{
    Step     = "Replication Sync"
    Status   = if ($synced) { "Success" } else { "TimedOut" }
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = if ($synced) { "Sync completed" } else { "Timed out after ${maxWait}s" }
}

Write-Host ""

# ── Step 3: Front Door Origin Priority Restore ──────────────────────────
Write-Host "[STEP 3/4] Restore Front Door Origin Priorities" -ForegroundColor Yellow
$stepStart = Get-Date

if (-not (Confirm-Step "Front Door Priority Restore")) {
    $stepResults += @{ Step = "Front Door Restore"; Status = "Skipped"; Duration = 0; Detail = "Operator skipped" }
}
else {
    try {
        if (-not $DryRun) {
            $originGroups = Get-AzFrontDoorCdnOriginGroup `
                -ResourceGroupName $Config.FrontDoorResourceGroup `
                -ProfileName $Config.FrontDoorProfileName

            foreach ($og in $originGroups) {
                $origins = Get-AzFrontDoorCdnOrigin `
                    -ResourceGroupName $Config.FrontDoorResourceGroup `
                    -ProfileName $Config.FrontDoorProfileName `
                    -OriginGroupName $og.Name

                foreach ($origin in $origins) {
                    $isPrimary = $origin.Name -match 'primary'
                    $newPriority = if ($isPrimary) { 1 } else { 2 }

                    Write-Host "  Origin: $($origin.Name) -> Priority $newPriority"

                    Update-AzFrontDoorCdnOrigin `
                        -ResourceGroupName $Config.FrontDoorResourceGroup `
                        -ProfileName $Config.FrontDoorProfileName `
                        -OriginGroupName $og.Name `
                        -OriginName $origin.Name `
                        -Priority $newPriority | Out-Null
                }
            }
        }

        Write-Host "  [OK] Primary origins restored to priority 1" -ForegroundColor Green
        $stepResults += @{
            Step     = "Front Door Restore"
            Status   = "Success"
            Duration = ((Get-Date) - $stepStart).TotalSeconds
            Detail   = "Primary origins restored to priority 1"
        }
    }
    catch {
        $stepResults += @{
            Step     = "Front Door Restore"
            Status   = "Failed"
            Duration = ((Get-Date) - $stepStart).TotalSeconds
            Detail   = $_.Exception.Message
        }
        Write-Host "  [FAILED] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# ── Step 4: Key Vault Restore (both vaults) ─────────────────────────────
Write-Host "[STEP 4/4] Restore Key Vault active-region (both vaults)" -ForegroundColor Yellow
$stepStart = Get-Date

if (-not (Confirm-Step "Key Vault Restore")) {
    $stepResults += @{ Step = "Key Vault Restore"; Status = "Skipped"; Duration = 0; Detail = "Operator skipped" }
}
else {
    foreach ($kvName in @($Config.KeyVaultPrimaryName, $Config.KeyVaultSecondaryName)) {
        try {
            if (-not $DryRun) {
                $secretValue = ConvertTo-SecureString -String $Config.PrimaryRegion -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $kvName -Name "active-region" -SecretValue $secretValue | Out-Null
                Write-Host "  [OK] $kvName active-region = $($Config.PrimaryRegion)" -ForegroundColor Green
            }
            else {
                Write-Host "  [DRY RUN] Would restore $kvName active-region = $($Config.PrimaryRegion)" -ForegroundColor Magenta
            }
        }
        catch {
            Write-Host "  [WARN] $kvName update failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $stepResults += @{
        Step     = "Key Vault Restore"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "active-region restored to $($Config.PrimaryRegion) in both vaults"
    }
}

# ── Summary ─────────────────────────────────────────────────────────────
$drillEnd = Get-Date
$totalDuration = ($drillEnd - $drillStart).TotalSeconds

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Planned Failback Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Total Duration: ${totalDuration}s"
Write-Host ""

foreach ($step in $stepResults) {
    $color = switch ($step.Status) {
        "Success"  { "Green" }
        "Skipped"  { "Gray" }
        "TimedOut" { "Yellow" }
        default    { "Red" }
    }
    Write-Host "  $($step.Step): $($step.Status) ($($step.Duration)s) - $($step.Detail)" -ForegroundColor $color
}

$global:FailbackResults = $stepResults
$global:FailbackStartTime = $drillStart

Write-Host ""
Write-Host "Results stored in `$global:FailbackResults" -ForegroundColor Gray
Write-Host "Proceed with: .\05-validate-failover.ps1 -OperationType failback" -ForegroundColor Gray
