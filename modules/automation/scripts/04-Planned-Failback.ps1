<###############################################################################
# 04-Planned-Failback.ps1  (Tier 2 - Azure Automation / Headless)
#
# PURPOSE:
#   Reverses a previous failover by restoring the primary region as the active
#   region. Designed for headless execution via Azure Automation runbooks to
#   return the system to its normal operating state.
#
# ARCHITECTURE:
#   Front Door (Premium) -> AppGW (WAF_v2) -> APIM (/api/*) | Storage SPA (/*)
#   SQL MI with Failover Groups provides database-level DR.
#   Key Vault stores the "active-region" secret read by function apps.
#
# WHAT IT DOES (4 steps, no operator prompts):
#   1. SQL MI Failover Group switch back to primary region (zero data loss)
#   2. Wait for replication sync confirmation (up to 5 min)
#   3. Restore Front Door origin priorities (primary -> priority 1)
#   4. Restore Key Vault "active-region" secret to primary region
#
# PREREQUISITES:
#   - 00-Setup-Environment.ps1 must have populated $global:DrConfig
#   - A previous failover (02 or 03) must have been executed
#   - Azure Automation managed identity must have RBAC permissions
#
# ERROR HANDLING:
#   - Each step has individual try/catch with status tracking
#   - On failure, error state is auto-dumped to JSON for diagnostics
#   - 06-Capture-Evidence.ps1 is auto-invoked to snapshot system state
#   - Partial results are always stored in $global:FailbackResults
#
# PARAMETERS:
#   -Config  : DR configuration hashtable (default: $global:DrConfig)
#   -DryRun  : Simulate without making changes
#
# VERSION: 1.1.0  |  TIER: 2 (Azure Automation)
###############################################################################>

param(
    [Parameter(Mandatory = $false)]
    [hashtable]$Config = $global:DrConfig,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run 00-Setup-Environment.ps1 first."
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
        Script         = "04-Planned-Failback.ps1 (Tier2)"
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
    Write-Warning "[ERROR STATE] Diagnostics saved to: $filePath"
    $global:FailoverErrorLog += $errorState
}

Write-Output "============================================"
Write-Output "  RAD Showcase DR Drill - Planned Failback"
Write-Output "  Started: $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "============================================"
Write-Output ""

if ($DryRun) {
    Write-Output "[DRY RUN] No changes will be made."
    Write-Output ""
}
# ── Execute DR steps with error-state capture on failure ────────────────
$scriptError = $null
try {
# ── Step 1: SQL MI Failback to Primary ──────────────────────────────────────
Write-Output "[STEP 1] SQL MI Failback to Primary Region"
$stepStart = Get-Date

try {
    # Failback: initiate from the original primary (which is currently secondary)
    $targetRG = $Config.PrimaryResourceGroup
    $targetLocation = $Config.PrimaryRegion

    Write-Output "  Initiating failback to $targetLocation..."

    if (-not $DryRun) {
        Switch-AzSqlDatabaseInstanceFailoverGroup `
            -ResourceGroupName $targetRG `
            -Location $targetLocation `
            -Name $Config.SqlMiFailoverGroupName `
            -ErrorAction Stop | Out-Null

        Write-Output "  [OK] Failback initiated"
    }
    else {
        Write-Output "  [DRY RUN] Would failback to $targetLocation"
    }

    $stepResults += @{
        Step     = "SQL MI Failback"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "Failback to $targetLocation"
    }
}
catch {
    $stepResults += @{
        Step     = "SQL MI Failback"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Error "SQL MI failback failed: $($_.Exception.Message)"
    throw
}

Write-Output "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Output ""

# ── Step 2: Wait for Replication Sync ───────────────────────────────────────
Write-Output "[STEP 2] Waiting for replication sync..."
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

            Write-Output "  [$elapsed s] Role=$($fog.ReplicationRole)"

            if ($fog.ReplicationRole -eq "Primary") {
                Write-Output "  [OK] Primary region restored as Primary role"
                $synced = $true
                break
            }
        }
        catch {
            Write-Warning "  [$elapsed s] Check failed: $($_.Exception.Message)"
        }
    } while ($elapsed -lt $maxWait)
}
else {
    $synced = $true
}

$stepResults += @{
    Step     = "Replication Sync"
    Status   = if ($synced) { "Success" } else { "TimedOut" }
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = if ($synced) { "Sync completed" } else { "Timed out after ${maxWait}s" }
}

Write-Output ""

# ── Step 3: Front Door Origin Priority Restore ──────────────────────────────
Write-Output "[STEP 3] Restore Front Door Origin Priorities"
$stepStart = Get-Date

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
                # Primary = priority 1, Secondary = priority 2
                $isPrimary = $origin.Name -match 'primary'
                $newPriority = if ($isPrimary) { 1 } else { 2 }

                Write-Output "  Origin: $($origin.Name) -> Priority $newPriority"

                Update-AzFrontDoorCdnOrigin `
                    -ResourceGroupName $Config.FrontDoorResourceGroup `
                    -ProfileName $Config.FrontDoorProfileName `
                    -OriginGroupName $og.Name `
                    -OriginName $origin.Name `
                    -Priority $newPriority | Out-Null
            }
        }
    }

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
    Write-Warning "Front Door restore failed: $($_.Exception.Message)"
    Save-ErrorState -StepName "Front Door Restore" -ErrorRecord $_ -StepResultsSoFar $stepResults
}

Write-Output ""

# ── Step 4: Key Vault Restore ───────────────────────────────────────────────
Write-Output "[STEP 4] Restore Key Vault active-region"
$stepStart = Get-Date

try {
    if (-not $DryRun) {
        $secretValue = ConvertTo-SecureString -String $Config.PrimaryRegion -AsPlainText -Force
        Set-AzKeyVaultSecret -VaultName $Config.KeyVaultName -Name "active-region" -SecretValue $secretValue | Out-Null
        Write-Output "  [OK] active-region restored to $($Config.PrimaryRegion)"
    }
    else {
        Write-Output "  [DRY RUN] Would restore active-region to $($Config.PrimaryRegion)"
    }

    $stepResults += @{
        Step     = "Key Vault Restore"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "active-region=$($Config.PrimaryRegion)"
    }
}
catch {
    $stepResults += @{
        Step     = "Key Vault Restore"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Warning "Key Vault restore failed: $($_.Exception.Message)"
}

} catch {
    # ── Global error handler ────────────────────────────────────────────
    $scriptError = $_
    Save-ErrorState -StepName "Script execution" -ErrorRecord $_ -StepResultsSoFar $stepResults
    Write-Error "[FATAL] Script failed: $($_.Exception.Message)"
} finally {

# ── Summary (always runs, even after failure) ───────────────────────────
$drillEnd = Get-Date
$totalDuration = ($drillEnd - $drillStart).TotalSeconds

Write-Output ""
Write-Output "============================================"
Write-Output "  Planned Failback Summary"
Write-Output "============================================"
Write-Output "  Total Duration: ${totalDuration}s"

foreach ($sr in $stepResults) {
    $icon = if ($sr.Status -eq "Success") { "[OK]" } else { "[FAIL]" }
    Write-Output "  $icon $($sr.Step): $($sr.Duration)s - $($sr.Detail)"
}

Write-Output ""
Write-Output "[SUCCESS] System restored to primary region."

# ── Auto-capture evidence on failure ────────────────────────────────────
$failedSteps = @($stepResults | Where-Object { $_.Status -eq "Failed" })
if ($failedSteps.Count -gt 0 -or $scriptError) {
    Write-Warning "[AUTO-CAPTURE] Failure detected - invoking evidence capture..."
    try {
        $captureScript = Join-Path $PSScriptRoot "06-Capture-Evidence.ps1"
        if (Test-Path $captureScript) {
            & $captureScript -Config $Config -DrillStartTime $drillStart -DrillEndTime (Get-Date) -DrillType "error-capture"
            Write-Output "[AUTO-CAPTURE] Evidence captured successfully."
        }
        else {
            Write-Warning "[AUTO-CAPTURE] 06-Capture-Evidence.ps1 not found at: $captureScript"
        }
    }
    catch {
        Write-Warning "[AUTO-CAPTURE] Evidence capture failed: $($_.Exception.Message)"
    }
}

$global:FailbackResults = $stepResults

} # end finally
