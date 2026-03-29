<#
.SYNOPSIS
    Unplanned Failover - Simulated outage with forced failover
.DESCRIPTION
    Simulates a real outage scenario by executing a forced failover
    that allows potential data loss (AllowDataLoss flag).
    Use for DR drills to test worst-case RTO/RPO.
.NOTES
    Version: 1.0.0
    WARNING: Forced failover may cause data loss in production.
#>

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
                $isSecondary = $origin.HostName -match $Config.SecondaryRegionShort -or
                               $origin.HostName -match "ncus"
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
}

# ── Summary ─────────────────────────────────────────────────────────────────
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

$global:FailoverResults = $stepResults
$global:FailoverRTO = $totalDuration
