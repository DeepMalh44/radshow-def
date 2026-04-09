<###############################################################################
# 02-Planned-Failover.ps1  (Tier 2 - Azure Automation / Headless)
#
# PURPOSE:
#   Executes a graceful, planned failover of the RAD Showcase application from
#   the primary region to the secondary region. Designed for headless execution
#   via Azure Automation runbooks with zero data loss.
#
# ARCHITECTURE:
#   Front Door (Premium) -> AppGW (WAF_v2) -> APIM (/api/*) | Storage SPA (/*)
#   SQL MI with Failover Groups provides database-level DR.
#   Key Vault stores the "active-region" secret read by function apps.
#
# WHAT IT DOES (4 steps, no operator prompts):
#   1. SQL MI Failover Group switch to secondary region (zero data loss)
#   2. Wait for replication sync confirmation (up to 5 min)
#   3. Swap Front Door origin priorities (secondary -> priority 1)
#   4. Update Key Vault "active-region" secret
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
        Script         = "02-Planned-Failover.ps1 (Tier2)"
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
Write-Output "  RAD Showcase DR Drill - Planned Failover"
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
# ── Step 1: SQL MI Failover Group Switch ────────────────────────────────────
Write-Output "[STEP 1] SQL MI Failover Group Switch"
$stepStart = Get-Date

try {
    $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
        -ResourceGroupName $Config.PrimaryResourceGroup `
        -Location $Config.PrimaryRegion `
        -Name $Config.SqlMiFailoverGroupName `
        -ErrorAction Stop

    Write-Output "  Current Primary: $($fog.PrimaryManagedInstanceName)"
    Write-Output "  Current Role: $($fog.ReplicationRole)"

    # Failover must be initiated from the secondary (target) region
    $targetRG = $Config.SecondaryResourceGroup
    $targetLocation = $Config.SecondaryRegion

    if (-not $DryRun) {
        Write-Output "  Initiating planned failover to $targetLocation..."

        Switch-AzSqlDatabaseInstanceFailoverGroup `
            -ResourceGroupName $targetRG `
            -Location $targetLocation `
            -Name $Config.SqlMiFailoverGroupName `
            -ErrorAction Stop | Out-Null

        Write-Output "  [OK] SQL MI failover initiated"
    }
    else {
        Write-Output "  [DRY RUN] Would failover to $targetLocation"
    }

    $stepResults += @{
        Step     = "SQL MI FOG Switch"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "Failover to $targetLocation"
    }
}
catch {
    $stepResults += @{
        Step     = "SQL MI FOG Switch"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Error "SQL MI failover failed: $($_.Exception.Message)"
    throw
}

Write-Output "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Output ""

# ── Step 2: Wait for Replication Sync ───────────────────────────────────────
Write-Output "[STEP 2] Waiting for replication sync..."
$stepStart = Get-Date

if (-not $DryRun) {
    $maxWait = 300  # 5 minutes
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
                -ErrorAction Stop

            Write-Output "  [$elapsed s] Role=$($fog.ReplicationRole), State=$($fog.ReplicationState)"

            if ($fog.ReplicationRole -eq "Primary") {
                Write-Output "  [OK] Secondary is now Primary"
                $synced = $true
                break
            }
        }
        catch {
            Write-Warning "  [$elapsed s] Check failed: $($_.Exception.Message)"
        }
    } while ($elapsed -lt $maxWait)

    if (-not $synced) {
        Write-Warning "  Replication sync timed out after $maxWait seconds"
    }
}
else {
    $synced = $true
    Write-Output "  [DRY RUN] Would wait for replication sync"
}

$stepResults += @{
    Step     = "Replication Sync"
    Status   = if ($synced) { "Success" } else { "TimedOut" }
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = if ($synced) { "Sync completed" } else { "Timed out after ${maxWait}s" }
}

Write-Output "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Output ""

# ── Step 3: Front Door Origin Priority Swap ─────────────────────────────────
Write-Output "[STEP 3] Front Door Origin Priority Swap"
$stepStart = Get-Date

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

            Write-Output "  Origin: $($origin.Name) -> Priority $newPriority"

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

    $stepResults += @{
        Step     = "Front Door Priority Swap"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "Origins re-prioritized"
    }
}
catch {
    $stepResults += @{
        Step     = "Front Door Priority Swap"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Warning "Front Door priority swap failed: $($_.Exception.Message)"
    Save-ErrorState -StepName "Front Door Priority Swap" -ErrorRecord $_ -StepResultsSoFar $stepResults
}

Write-Output "  Duration: $(((Get-Date) - $stepStart).TotalSeconds)s"
Write-Output ""

# ── Step 4: Update Key Vault active-region ──────────────────────────────────
Write-Output "[STEP 4] Update Key Vault active-region"
$stepStart = Get-Date

try {
    $newRegion = $Config.SecondaryRegion

    if (-not $DryRun) {
        $secretValue = ConvertTo-SecureString -String $newRegion -AsPlainText -Force
        Set-AzKeyVaultSecret -VaultName $Config.KeyVaultName -Name "active-region" -SecretValue $secretValue -ErrorAction Stop | Out-Null
        Write-Output "  [OK] active-region set to $newRegion"
    }
    else {
        Write-Output "  [DRY RUN] Would set active-region to $newRegion"
    }

    $stepResults += @{
        Step     = "Key Vault Update"
        Status   = "Success"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = "active-region=$newRegion"
    }
}
catch {
    $stepResults += @{
        Step     = "Key Vault Update"
        Status   = "Failed"
        Duration = ((Get-Date) - $stepStart).TotalSeconds
        Detail   = $_.Exception.Message
    }
    Write-Warning "Key Vault update failed: $($_.Exception.Message)"
}

Write-Output ""

} catch {
    # ── Global error handler ────────────────────────────────────────────
    $scriptError = $_
    Save-ErrorState -StepName "Script execution" -ErrorRecord $_ -StepResultsSoFar $stepResults
    Write-Error "[FATAL] Script failed: $($_.Exception.Message)"
} finally {

# ── Summary (always runs, even after failure) ───────────────────────────
$drillEnd = Get-Date
$totalDuration = ($drillEnd - $drillStart).TotalSeconds

Write-Output "============================================"
Write-Output "  Planned Failover Summary"
Write-Output "============================================"
Write-Output "  Started:  $($drillStart.ToString('HH:mm:ss'))"
Write-Output "  Finished: $($drillEnd.ToString('HH:mm:ss'))"
Write-Output "  Total:    ${totalDuration}s"
Write-Output ""

foreach ($sr in $stepResults) {
    $icon = if ($sr.Status -eq "Success") { "[OK]" } else { "[FAIL]" }
    Write-Output "  $icon $($sr.Step): $($sr.Duration)s - $($sr.Detail)"
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
