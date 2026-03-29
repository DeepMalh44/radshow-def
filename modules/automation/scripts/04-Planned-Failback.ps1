<#
.SYNOPSIS
    Planned Failback - Return to primary region
.DESCRIPTION
    Reverses a previous failover, restoring primary region as active:
    1. SQL MI FOG switch back to primary
    2. Wait for replication sync
    3. Front Door origin priority restore
    4. Key Vault active-region restore
.NOTES
    Version: 1.0.0
    Requires: 00-Setup-Environment.ps1 executed first
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
Write-Output "  RAD Showcase DR Drill - Planned Failback"
Write-Output "  Started: $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "============================================"
Write-Output ""

if ($DryRun) {
    Write-Output "[DRY RUN] No changes will be made."
    Write-Output ""
}

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
                $isPrimary = $origin.HostName -match $Config.PrimaryRegionShort -or
                             $origin.HostName -match "scus"
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

# ── Summary ─────────────────────────────────────────────────────────────────
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

$global:FailbackResults = $stepResults
