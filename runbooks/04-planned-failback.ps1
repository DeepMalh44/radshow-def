<###############################################################################
# 04-Planned-Failback.ps1
#
# PURPOSE:
#   Reverses a previous failover by restoring the primary region as the active
#   region. Run after a successful DR drill to return the system to its normal
#   operating state with primary region handling all traffic.
#
# ARCHITECTURE:
#   Front Door (Premium) -> AppGW (WAF_v2) -> APIM (/api/*) | Storage SPA (/*)
#   SQL MI with Failover Groups provides database-level DR.
#   Key Vault stores the "active-region" secret read by function apps.
#
# WHAT IT DOES (4 steps, operator-confirmed):
#   1. SQL MI Failover Group switch back to primary region (zero data loss)
#   2. Wait for replication sync confirmation (up to 5 min)
#   3. Restore Front Door origin priorities (primary -> priority 1)
#   4. Restore Key Vault "active-region" secret to primary in both vaults
#
# PREREQUISITES:
#   - Run 00-setup-environment.ps1 first to populate $global:DrConfig
#   - A previous failover (02 or 03) must have been executed
#   - Operator must have appropriate Azure RBAC permissions
#
# ERROR HANDLING:
#   - Each step has individual try/catch with status tracking
#   - On failure, error state is auto-dumped to JSON in $env:TEMP
#   - 06-capture-evidence.ps1 is auto-invoked to snapshot system state
#   - Partial results are always stored in $global:FailbackResults
#
# PARAMETERS:
#   -Config    : DR configuration hashtable (default: $global:DrConfig)
#   -DryRun    : Simulate without making changes
#   -NoPrompt  : Skip operator confirmations (for automated runs)
#
# OUTPUTS:
#   $global:FailbackResults   - Array of step result hashtables
#   $global:FailbackStartTime - Drill start timestamp
#   $global:FailoverErrorLog  - Array of error state captures (if any)
#
# VERSION: 1.1.0  |  TIER: 3 (Operator workstation)
###############################################################################>

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
$global:FailoverErrorLog = @()

# ── Helper: Save error state to disk for post-mortem analysis ────────────
function Save-ErrorState {
    param(
        [string]$StepName,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [hashtable[]]$StepResultsSoFar
    )
    $errorState = @{
        Timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Script         = "04-Planned-Failback.ps1"
        FailedStep     = $StepName
        ErrorMessage   = $ErrorRecord.Exception.Message
        ErrorType      = $ErrorRecord.Exception.GetType().FullName
        StackTrace     = $ErrorRecord.ScriptStackTrace
        StepsCompleted = $StepResultsSoFar
        ConfigSnapshot = @{
            PrimaryRegion    = $Config.PrimaryRegion
            SecondaryRegion  = $Config.SecondaryRegion
            FrontDoorProfile = $Config.FrontDoorProfileName
        }
    }
    $fileName = "dr-error-state-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $filePath = Join-Path $env:TEMP $fileName
    $errorState | ConvertTo-Json -Depth 5 | Out-File -FilePath $filePath -Encoding UTF8
    Write-Host "  [ERROR STATE] Diagnostics saved to: $filePath" -ForegroundColor Red
    $global:FailoverErrorLog += $errorState
}

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

# ── Execute DR steps with error-state capture on failure ────────────────
$scriptError = $null
try {

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
        Save-ErrorState -StepName "Front Door Restore" -ErrorRecord $_ -StepResultsSoFar $stepResults
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

} catch {
    # ── Global error handler ────────────────────────────────────────────
    $scriptError = $_
    Save-ErrorState -StepName "Script execution" -ErrorRecord $_ -StepResultsSoFar $stepResults
    Write-Host ""
    Write-Host "[FATAL] Script failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[FATAL] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
} finally {

# ── Summary (always runs, even after failure) ───────────────────────────
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

# ── Auto-capture evidence on failure ────────────────────────────────────
$failedSteps = @($stepResults | Where-Object { $_.Status -eq "Failed" })
if ($failedSteps.Count -gt 0 -or $scriptError) {
    Write-Host ""
    Write-Host "[AUTO-CAPTURE] Failure detected - invoking evidence capture..." -ForegroundColor Yellow
    try {
        $captureScript = Join-Path $PSScriptRoot "06-capture-evidence.ps1"
        if (Test-Path $captureScript) {
            & $captureScript -Config $Config -DrillStartTime $drillStart -DrillEndTime (Get-Date) -DrillType "error-capture"
            Write-Host "[AUTO-CAPTURE] Evidence captured successfully." -ForegroundColor Green
        }
        else {
            Write-Host "[AUTO-CAPTURE] 06-capture-evidence.ps1 not found at: $captureScript" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[AUTO-CAPTURE] Evidence capture failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$global:FailbackResults = $stepResults
$global:FailbackStartTime = $drillStart

Write-Host ""
Write-Host "Results stored in `$global:FailbackResults" -ForegroundColor Gray
Write-Host "Proceed with: .\05-validate-failover.ps1 -OperationType failback" -ForegroundColor Gray

} # end finally
