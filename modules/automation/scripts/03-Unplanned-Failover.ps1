<###############################################################################
# 03-Unplanned-Failover.ps1  (Tier 2 - Azure Automation / Headless)
#
# PURPOSE:
#   Simulates a real outage by executing a forced failover with the AllowDataLoss
#   flag. Designed for headless execution via Azure Automation runbooks to test
#   worst-case RTO/RPO.
#
# ARCHITECTURE:
#   Front Door (Premium) -> AppGW (WAF_v2) -> APIM (/api/*) | Storage SPA (/*)
#   SQL MI with Failover Groups provides database-level DR.
#   Key Vault stores the "active-region" secret read by function apps.
#
# WHAT IT DOES (3 steps, no operator prompts):
#   1. Forced SQL MI Failover Group switch (AllowDataLoss - potential data loss!)
#   2. Wait for secondary to assume Primary role (up to 10 min)
#   3. Swap Front Door origin priorities + update Key Vault active-region
#
# WARNING:
#   Forced failover uses AllowDataLoss. Any uncommitted transactions on the
#   primary SQL MI may be permanently lost.
#
# PREREQUISITES:
#   - 00-Setup-Environment.ps1 must have populated $global:DrConfig
#   - Azure Automation managed identity must have RBAC permissions
#
# ERROR HANDLING:
#   - Each step has individual try/catch with status tracking
#   - On failure, error state is auto-dumped to JSON for diagnostics
#   - 06-Capture-Evidence.ps1 is auto-invoked to snapshot system state
#   - Partial results are always stored in $global:FailoverResults
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
        Script         = "03-Unplanned-Failover.ps1 (Tier2)"
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
Write-Output "  RAD Showcase DR Drill - UNPLANNED Failover"
Write-Output "  Started: $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "============================================"
Write-Output ""
Write-Output "[WARNING] This executes a FORCED failover (AllowDataLoss)."
Write-Output ""

if ($DryRun) {
    Write-Output "[DRY RUN] No changes will be made."
    Write-Output ""
}
# ── Execute DR steps with error-state capture on failure ────────────────
$scriptError = $null
try {
# ── Step 1: Forced SQL MI Failover Group Switch ─────────────────────────────
Write-Output "[STEP 1] SQL MI Forced Failover (AllowDataLoss)"
$stepStart = Get-Date

try {
    # Initiate forced failover from secondary
    $targetRG = $Config.SecondaryResourceGroup
    $targetLocation = $Config.SecondaryRegion

    Write-Output "  Target: $targetLocation (forced, allow data loss)"

    if (-not $DryRun) {
        Switch-AzSqlDatabaseInstanceFailoverGroup `
            -ResourceGroupName $targetRG `
            -Location $targetLocation `
            -Name $Config.SqlMiFailoverGroupName `
            -AllowDataLoss `
            -ErrorAction Stop | Out-Null

        Write-Output "  [OK] Forced failover initiated"
    }
    else {
        Write-Output "  [DRY RUN] Would force failover to $targetLocation"
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
    Write-Error "Forced failover failed: $($_.Exception.Message)"
    throw
}

Write-Output "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Output ""

# ── Step 2: Wait for role switch ────────────────────────────────────────────
Write-Output "[STEP 2] Waiting for secondary to assume Primary role..."
$stepStart = Get-Date

if (-not $DryRun) {
    $maxWait = 600  # 10 minutes for forced failover
    $elapsed = 0
    $interval = 15
    $synced = $false

    do {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        try {
            $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
                -ResourceGroupName $Config.SecondaryResourceGroup `
                -Location $Config.SecondaryRegion `
                -Name $Config.SqlMiFailoverGroupName `
                -ErrorAction SilentlyContinue

            if ($fog -and $fog.ReplicationRole -eq "Primary") {
                Write-Output "  [$elapsed s] Secondary now Primary"
                $synced = $true
                break
            }
            Write-Output "  [$elapsed s] Waiting... Role=$($fog.ReplicationRole)"
        }
        catch {
            Write-Output "  [$elapsed s] Waiting... (endpoint not ready)"
        }
    } while ($elapsed -lt $maxWait)
}
else {
    $synced = $true
}

$stepResults += @{
    Step     = "Role Switch Wait"
    Status   = if ($synced) { "Success" } else { "TimedOut" }
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = if ($synced) { "Role switch confirmed" } else { "Timed out after ${maxWait}s" }
}

Write-Output ""

# ── Step 3: Front Door Priority + Key Vault ─────────────────────────────────
Write-Output "[STEP 3] Front Door + Key Vault update"
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
                $isSecondary = $origin.Name -match 'secondary'
                $newPriority = if ($isSecondary) { 1 } else { 2 }

                Update-AzFrontDoorCdnOrigin `
                    -ResourceGroupName $Config.FrontDoorResourceGroup `
                    -ProfileName $Config.FrontDoorProfileName `
                    -OriginGroupName $og.Name `
                    -OriginName $origin.Name `
                    -Priority $newPriority | Out-Null
            }
        }
        Write-Output "  [OK] Front Door origins re-prioritized"

        # Key Vault
        $secretValue = ConvertTo-SecureString -String $Config.SecondaryRegion -AsPlainText -Force
        Set-AzKeyVaultSecret -VaultName $Config.KeyVaultName -Name "active-region" -SecretValue $secretValue | Out-Null
        Write-Output "  [OK] Key Vault active-region updated"
    }

    $stepResults += @{
        Step     = "FD + KV Update"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "Priorities swapped, KV updated"
    }
}
catch {
    $stepResults += @{
        Step     = "FD + KV Update"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Warning "FD/KV update failed: $($_.Exception.Message)"
    Save-ErrorState -StepName "FD + KV Update" -ErrorRecord $_ -StepResultsSoFar $stepResults
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
Write-Output "  Unplanned Failover Summary"
Write-Output "============================================"
Write-Output "  Total RTO: ${totalDuration}s"

foreach ($sr in $stepResults) {
    $icon = if ($sr.Status -eq "Success") { "[OK]" } else { "[FAIL]" }
    Write-Output "  $icon $($sr.Step): $($sr.Duration)s"
}

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

$global:FailoverResults = $stepResults
$global:FailoverRTO = $totalDuration

} # end finally
