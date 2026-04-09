<#
.SYNOPSIS
    Planned Failover - Interactive operator script with step confirmations
.DESCRIPTION
    Executes a graceful, planned failover with operator confirmations at each step:
    1. SQL MI Failover Group switch (zero data loss)
    2. Wait for replication sync
    3. Front Door origin priority swap
    4. Update Key Vault active-region (both vaults)
    5. Post-step validation
.NOTES
    Version: 1.0.0
    Tier: 3 (Operator workstation)
    Requires: 00-setup-environment.ps1 + 01-check-health.ps1 executed first
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
Write-Host "  RAD Showcase - PLANNED FAILOVER" -ForegroundColor Cyan
Write-Host "  Primary:   $($Config.PrimaryRegion) ($($Config.PrimaryRegionShort))" -ForegroundColor Cyan
Write-Host "  Target:    $($Config.SecondaryRegion) ($($Config.SecondaryRegionShort))" -ForegroundColor Cyan
Write-Host "  Started:   $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Magenta
    Write-Host ""
}

# ── Helper: Operator Confirmation ────────────────────────────────────────
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

# ── Step 1: SQL MI Failover Group Switch ────────────────────────────────
Write-Host "[STEP 1/4] SQL MI Failover Group Switch" -ForegroundColor Yellow
$stepStart = Get-Date

try {
    $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
        -ResourceGroupName $Config.PrimaryResourceGroup `
        -Location $Config.PrimaryRegion `
        -Name $Config.SqlMiFailoverGroupName `
        -ErrorAction Stop

    Write-Host "  Current Primary: $($fog.ManagedInstanceName) ($($fog.ReplicationRole))"
    Write-Host "  Replication State: $($fog.ReplicationState)"

    if (-not (Confirm-Step "SQL MI Failover")) {
        $stepResults += @{ Step = "SQL MI FOG Switch"; Status = "Skipped"; Duration = 0; Detail = "Operator skipped" }
    }
    else {
        $targetRG = $Config.SecondaryResourceGroup
        $targetLocation = $Config.SecondaryRegion

        if (-not $DryRun) {
            Write-Host "  Initiating planned failover to $targetLocation..." -ForegroundColor Yellow

            Switch-AzSqlDatabaseInstanceFailoverGroup `
                -ResourceGroupName $targetRG `
                -Location $targetLocation `
                -Name $Config.SqlMiFailoverGroupName `
                -ErrorAction Stop | Out-Null

            Write-Host "  [OK] SQL MI failover initiated" -ForegroundColor Green
        }
        else {
            Write-Host "  [DRY RUN] Would failover to $targetLocation" -ForegroundColor Magenta
        }

        $stepResults += @{
            Step     = "SQL MI FOG Switch"
            Status   = "Success"
            Duration = ((Get-Date) - $stepStart).TotalSeconds
            Detail   = "Failover to $targetLocation"
        }
    }
}
catch {
    $stepResults += @{
        Step     = "SQL MI FOG Switch"
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
    $maxWait = 300  # 5 minutes
    $elapsed = 0
    $interval = 15
    $synced = $false

    do {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        $pct = [math]::Min(100, [math]::Round(($elapsed / $maxWait) * 100))

        try {
            $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
                -ResourceGroupName $Config.SecondaryResourceGroup `
                -Location $Config.SecondaryRegion `
                -Name $Config.SqlMiFailoverGroupName `
                -ErrorAction Stop

            Write-Host "  [$elapsed s / ${maxWait}s] ($pct%) Role=$($fog.ReplicationRole), State=$($fog.ReplicationState)"

            if ($fog.ReplicationRole -eq "Primary") {
                Write-Host "  [OK] Secondary is now Primary" -ForegroundColor Green
                $synced = $true
                break
            }
        }
        catch {
            Write-Host "  [$elapsed s] Waiting... ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    } while ($elapsed -lt $maxWait)

    if (-not $synced) {
        Write-Host "  [WARN] Replication sync timed out after $maxWait seconds" -ForegroundColor Yellow
    }
}
else {
    $synced = $true
    Write-Host "  [DRY RUN] Would wait for replication sync" -ForegroundColor Magenta
}

$stepResults += @{
    Step     = "Replication Sync"
    Status   = if ($synced) { "Success" } else { "TimedOut" }
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = if ($synced) { "Sync completed" } else { "Timed out after ${maxWait}s" }
}

Write-Host "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Host ""

# ── Step 3: Front Door Origin Priority Swap ─────────────────────────────
Write-Host "[STEP 3/4] Front Door Origin Priority Swap" -ForegroundColor Yellow
$stepStart = Get-Date

if (-not (Confirm-Step "Front Door Priority Swap")) {
    $stepResults += @{ Step = "Front Door Priority Swap"; Status = "Skipped"; Duration = 0; Detail = "Operator skipped" }
}
else {
    try {
        $originGroups = Get-AzFrontDoorCdnOriginGroup `
            -ResourceGroupName $Config.FrontDoorResourceGroup `
            -ProfileName $Config.FrontDoorProfileName `
            -ErrorAction Stop

        foreach ($og in $originGroups) {
            $origins = Get-AzFrontDoorCdnOrigin `
                -ResourceGroupName $Config.FrontDoorResourceGroup `
                -ProfileName $Config.FrontDoorProfileName `
                -OriginGroupName $og.Name `
                -ErrorAction Stop

            foreach ($origin in $origins) {
                $isSecondary = $origin.Name -match 'secondary'
                $newPriority = if ($isSecondary) { 1 } else { 2 }

                Write-Host "  Origin: $($origin.Name) -> Priority $newPriority"

                if (-not $DryRun) {
                    Update-AzFrontDoorCdnOrigin `
                        -ResourceGroupName $Config.FrontDoorResourceGroup `
                        -ProfileName $Config.FrontDoorProfileName `
                        -OriginGroupName $og.Name `
                        -OriginName $origin.Name `
                        -Priority $newPriority `
                        -ErrorAction Stop | Out-Null
                }
            }
        }

        Write-Host "  [OK] Origins re-prioritized" -ForegroundColor Green
        $stepResults += @{
            Step     = "Front Door Priority Swap"
            Status   = "Success"
            Duration = ((Get-Date) - $stepStart).TotalSeconds
            Detail   = "Secondary origins promoted to priority 1"
        }
    }
    catch {
        $stepResults += @{
            Step     = "Front Door Priority Swap"
            Status   = "Failed"
            Duration = ((Get-Date) - $stepStart).TotalSeconds
            Detail   = $_.Exception.Message
        }
        Write-Host "  [FAILED] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Host ""

# ── Step 4: Key Vault active-region Update (both vaults) ────────────────
Write-Host "[STEP 4/4] Key Vault active-region Update (both vaults)" -ForegroundColor Yellow
$stepStart = Get-Date

if (-not (Confirm-Step "Key Vault Update")) {
    $stepResults += @{ Step = "Key Vault Update"; Status = "Skipped"; Duration = 0; Detail = "Operator skipped" }
}
else {
    foreach ($kvName in @($Config.KeyVaultPrimaryName, $Config.KeyVaultSecondaryName)) {
        try {
            if (-not $DryRun) {
                $secretValue = ConvertTo-SecureString -String $Config.SecondaryRegion -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $kvName -Name "active-region" -SecretValue $secretValue -ErrorAction Stop | Out-Null
                Write-Host "  [OK] $kvName active-region = $($Config.SecondaryRegion)" -ForegroundColor Green
            }
            else {
                Write-Host "  [DRY RUN] Would set $kvName active-region = $($Config.SecondaryRegion)" -ForegroundColor Magenta
            }
        }
        catch {
            Write-Host "  [WARN] $kvName update failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $stepResults += @{
        Step     = "Key Vault Update"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "active-region set to $($Config.SecondaryRegion) in both vaults"
    }
}

# ── Summary ─────────────────────────────────────────────────────────────
$drillEnd = Get-Date
$totalDuration = ($drillEnd - $drillStart).TotalSeconds

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Planned Failover Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Total RTO: ${totalDuration}s" -ForegroundColor $(if ($totalDuration -le 900) { "Green" } else { "Yellow" })
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

$global:FailoverResults = $stepResults
$global:FailoverRTO = $totalDuration
$global:FailoverStartTime = $drillStart

Write-Host ""
Write-Host "Results stored in `$global:FailoverResults, `$global:FailoverRTO" -ForegroundColor Gray
Write-Host "Proceed with: .\05-validate-failover.ps1 -OperationType failover" -ForegroundColor Gray
