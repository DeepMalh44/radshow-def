<#
.SYNOPSIS
    Unplanned Failover - Forced failover with explicit danger warnings
.DESCRIPTION
    Simulates a real outage scenario by executing a forced failover (AllowDataLoss).
    Includes double-confirmation gates and explicit danger warnings.
    Use for DR drills to test worst-case RTO/RPO.
.NOTES
    Version: 1.0.0
    Tier: 3 (Operator workstation)
    WARNING: Forced failover may result in data loss.
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
Write-Host "============================================" -ForegroundColor Red
Write-Host "  RAD Showcase - UNPLANNED FAILOVER" -ForegroundColor Red
Write-Host "  !! FORCED - POTENTIAL DATA LOSS !!" -ForegroundColor Red
Write-Host "============================================" -ForegroundColor Red
Write-Host ""
Write-Host "  Primary:   $($Config.PrimaryRegion) ($($Config.PrimaryRegionShort))"
Write-Host "  Target:    $($Config.SecondaryRegion) ($($Config.SecondaryRegionShort))"
Write-Host "  Started:   $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Magenta
    Write-Host ""
}

# ── Double confirmation for forced failover ──────────────────────────────
if (-not $NoPrompt -and -not $DryRun) {
    Write-Host "[WARNING] This will execute a FORCED failover with AllowDataLoss flag." -ForegroundColor Red
    Write-Host "[WARNING] Any uncommitted transactions on the primary may be lost." -ForegroundColor Red
    Write-Host ""
    $confirm1 = Read-Host "Type 'FORCE' to confirm forced failover"
    if ($confirm1 -ne "FORCE") {
        Write-Host "Aborted. Input did not match 'FORCE'." -ForegroundColor Yellow
        return
    }
    $confirm2 = Read-Host "Are you absolutely sure? [YES/NO]"
    if ($confirm2 -ne "YES") {
        Write-Host "Aborted by operator." -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "[CONFIRMED] Proceeding with forced failover..." -ForegroundColor Red
    Write-Host ""
}

# ── Step 1: Forced SQL MI Failover Group Switch ─────────────────────────
Write-Host "[STEP 1/3] SQL MI Forced Failover (AllowDataLoss)" -ForegroundColor Yellow
$stepStart = Get-Date

try {
    $targetRG = $Config.SecondaryResourceGroup
    $targetLocation = $Config.SecondaryRegion

    Write-Host "  Target: $targetLocation (forced, AllowDataLoss)"

    if (-not $DryRun) {
        Switch-AzSqlDatabaseInstanceFailoverGroup `
            -ResourceGroupName $targetRG `
            -Location $targetLocation `
            -Name $Config.SqlMiFailoverGroupName `
            -AllowDataLoss `
            -ErrorAction Stop | Out-Null

        Write-Host "  [OK] Forced failover initiated" -ForegroundColor Green
    }
    else {
        Write-Host "  [DRY RUN] Would force failover to $targetLocation" -ForegroundColor Magenta
    }

    $stepResults += @{
        Step     = "SQL MI Forced Failover"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "Forced failover to $targetLocation"
    }
}
catch {
    $stepResults += @{
        Step     = "SQL MI Forced Failover"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Host "  [FAILED] $($_.Exception.Message)" -ForegroundColor Red
    throw
}

Write-Host "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Host ""

# ── Step 2: Wait for role switch (longer timeout for forced) ────────────
Write-Host "[STEP 2/3] Waiting for secondary to assume Primary role..." -ForegroundColor Yellow
$stepStart = Get-Date

if (-not $DryRun) {
    $maxWait = 600  # 10 minutes for forced failover
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
                -ErrorAction SilentlyContinue

            if ($fog -and $fog.ReplicationRole -eq "Primary") {
                Write-Host "  [$elapsed s] Secondary now Primary" -ForegroundColor Green
                $synced = $true
                break
            }
            Write-Host "  [$elapsed s / ${maxWait}s] ($pct%) Waiting... Role=$($fog.ReplicationRole)"
        }
        catch {
            Write-Host "  [$elapsed s] Waiting... (endpoint not ready)" -ForegroundColor Yellow
        }
    } while ($elapsed -lt $maxWait)

    if (-not $synced) {
        Write-Host "  [WARN] Role switch timed out after $maxWait seconds" -ForegroundColor Yellow
    }
}
else {
    $synced = $true
    Write-Host "  [DRY RUN] Would wait for role switch" -ForegroundColor Magenta
}

$stepResults += @{
    Step     = "Role Switch Wait"
    Status   = if ($synced) { "Success" } else { "TimedOut" }
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = if ($synced) { "Role switch confirmed" } else { "Timed out after ${maxWait}s" }
}

Write-Host ""

# ── Step 3: Front Door + Key Vault update ────────────────────────────────
Write-Host "[STEP 3/3] Front Door Priority + Key Vault Update" -ForegroundColor Yellow
$stepStart = Get-Date

try {
    if (-not $DryRun) {
        # Front Door origins
        $originGroups = Get-AzFrontDoorCdnOriginGroup `
            -ResourceGroupName $Config.FrontDoorResourceGroup `
            -ProfileName $Config.FrontDoorProfileName `
            -ErrorAction Stop

        foreach ($og in $originGroups) {
            $origins = Get-AzFrontDoorCdnOrigin `
                -ResourceGroupName $Config.FrontDoorResourceGroup `
                -ProfileName $Config.FrontDoorProfileName `
                -OriginGroupName $og.Name

            foreach ($origin in $origins) {
                $isSecondary = $origin.HostName -match $Config.SecondaryRegionShort
                $newPriority = if ($isSecondary) { 1 } else { 2 }

                Update-AzFrontDoorCdnOrigin `
                    -ResourceGroupName $Config.FrontDoorResourceGroup `
                    -ProfileName $Config.FrontDoorProfileName `
                    -OriginGroupName $og.Name `
                    -OriginName $origin.Name `
                    -Priority $newPriority | Out-Null
            }
        }
        Write-Host "  [OK] Front Door origins re-prioritized" -ForegroundColor Green

        # Key Vault (both vaults for dual-region resilience)
        foreach ($kvName in @($Config.KeyVaultPrimaryName, $Config.KeyVaultSecondaryName)) {
            try {
                $secretValue = ConvertTo-SecureString -String $Config.SecondaryRegion -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $kvName -Name "active-region" -SecretValue $secretValue | Out-Null
                Write-Host "  [OK] $kvName active-region = $($Config.SecondaryRegion)" -ForegroundColor Green
            }
            catch {
                Write-Host "  [WARN] $kvName update failed (non-fatal): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "  [DRY RUN] Would update Front Door + Key Vaults" -ForegroundColor Magenta
    }

    $stepResults += @{
        Step     = "FD + KV Update"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "Priorities swapped, KV updated in both regions"
    }
}
catch {
    $stepResults += @{
        Step     = "FD + KV Update"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Host "  [FAILED] $($_.Exception.Message)" -ForegroundColor Red
}

# ── Summary ─────────────────────────────────────────────────────────────
$drillEnd = Get-Date
$totalDuration = ($drillEnd - $drillStart).TotalSeconds

Write-Host ""
Write-Host "============================================" -ForegroundColor Red
Write-Host "  Unplanned Failover Summary" -ForegroundColor Red
Write-Host "============================================" -ForegroundColor Red
Write-Host "  Total RTO: ${totalDuration}s" -ForegroundColor $(if ($totalDuration -le 900) { "Green" } else { "Yellow" })
Write-Host ""

foreach ($step in $stepResults) {
    $color = switch ($step.Status) {
        "Success"  { "Green" }
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
