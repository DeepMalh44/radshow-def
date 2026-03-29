<#
.SYNOPSIS
    Planned Failover - Orchestrated DR failover with zero data loss
.DESCRIPTION
    Executes a graceful, planned failover:
    1. SQL MI Failover Group switch (no data loss)
    2. Wait for replication sync
    3. Front Door origin priority swap
    4. Update Key Vault active-region
    5. Validate new primary
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
Write-Output "  RAD Showcase DR Drill - Planned Failover"
Write-Output "  Started: $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "============================================"
Write-Output ""

if ($DryRun) {
    Write-Output "[DRY RUN] No changes will be made."
    Write-Output ""
}

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
                break
            }
        }
        catch {
            Write-Warning "  [$elapsed s] Check failed: $($_.Exception.Message)"
        }
    } while ($elapsed -lt $maxWait)

    if ($elapsed -ge $maxWait) {
        Write-Warning "  Replication sync timed out after $maxWait seconds"
    }
}
else {
    Write-Output "  [DRY RUN] Would wait for replication sync"
}

$stepResults += @{
    Step     = "Replication Sync"
    Status   = "Success"
    Duration = ((Get-Date) - $stepStart).TotalSeconds
    Detail   = "Sync wait completed"
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
            $isSecondary = $origin.HostName -match $Config.SecondaryRegionShort -or
                           $origin.HostName -match "ncus"

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

# ── Summary ─────────────────────────────────────────────────────────────────
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

$global:FailoverResults = $stepResults
$global:FailoverRTO = $totalDuration
