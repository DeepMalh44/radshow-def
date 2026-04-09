<#
.SYNOPSIS
    Capture DR Drill Evidence - Export logs, metrics, and timestamps
.DESCRIPTION
    Collects evidence from a completed DR drill for compliance and review:
    - Activity log entries during the drill window
    - SQL MI FOG status snapshots
    - Front Door health metrics
    - Key Vault audit events
    - RTO/RPO measurements
    Outputs a JSON evidence file and summary report.
.NOTES
    Version: 1.0.0
    Requires: 00-Setup-Environment.ps1 executed first
#>

param(
    [Parameter(Mandatory = $false)]
    [hashtable]$Config = $global:DrConfig,

    [Parameter(Mandatory = $true)]
    [datetime]$DrillStartTime,

    [Parameter(Mandatory = $false)]
    [datetime]$DrillEndTime = (Get-Date),

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [double]$MeasuredRTO = 0,

    [Parameter(Mandatory = $false)]
    [string]$DrillType = "PlannedFailover"
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run 00-Setup-Environment.ps1 first."
    throw
}

$evidence = @{
    DrillMetadata = @{
        ProjectName  = $Config.ProjectName
        Environment  = $Config.Environment
        DrillType    = $DrillType
        StartTime    = $DrillStartTime.ToString("o")
        EndTime      = $DrillEndTime.ToString("o")
        DurationSec  = ($DrillEndTime - $DrillStartTime).TotalSeconds
        MeasuredRTO  = $MeasuredRTO
        CapturedAt   = (Get-Date).ToString("o")
        CapturedBy   = (Get-AzContext).Account.Id
    }
    Components = @{}
    ActivityLogs = @()
}

Write-Output "============================================"
Write-Output "  RAD Showcase - Evidence Capture"
Write-Output "  Drill Window: $($DrillStartTime.ToString('HH:mm:ss')) - $($DrillEndTime.ToString('HH:mm:ss'))"
Write-Output "============================================"
Write-Output ""

# ── 1. SQL MI FOG Status Snapshot ───────────────────────────────────────────
Write-Output "[CAPTURE] SQL MI Failover Group Status"
try {
    foreach ($pair in @(
        @{ RG = $Config.PrimaryResourceGroup; Loc = $Config.PrimaryRegion; Label = "Primary" }
        @{ RG = $Config.SecondaryResourceGroup; Loc = $Config.SecondaryRegion; Label = "Secondary" }
    )) {
        try {
            $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
                -ResourceGroupName $pair.RG `
                -Location $pair.Loc `
                -Name $Config.SqlMiFailoverGroupName `
                -ErrorAction Stop

            $evidence.Components["SqlMiFog_$($pair.Label)"] = @{
                ReplicationRole  = $fog.ReplicationRole
                ReplicationState = $fog.ReplicationState
                PrimaryMI        = $fog.ManagedInstanceName
                PartnerMI        = $fog.PartnerManagedInstanceId.Split('/')[-1]
            }
            Write-Output "  $($pair.Label): Role=$($fog.ReplicationRole), State=$($fog.ReplicationState)"
        }
        catch {
            Write-Output "  $($pair.Label): Not reachable"
        }
    }
}
catch {
    Write-Warning "  SQL MI capture failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 2. Redis Status ─────────────────────────────────────────────────────────
Write-Output "[CAPTURE] Redis Cache Status"
foreach ($pair in @(
    @{ Name = $Config.RedisPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.RedisSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $redis = Get-AzRedisCache -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $evidence.Components["Redis_$($pair.Label)"] = @{
            ProvisioningState = $redis.ProvisioningState
            HostName          = $redis.HostName
            Port              = $redis.Port
            Sku               = $redis.Sku.Name
        }
        Write-Output "  $($pair.Label): $($redis.ProvisioningState)"
    }
    catch {
        Write-Output "  $($pair.Label): Not reachable"
    }
}

Write-Output ""

# ── 3. Front Door Status ───────────────────────────────────────────────────
Write-Output "[CAPTURE] Front Door Status"
try {
    $fd = Get-AzFrontDoorCdnProfile `
        -ResourceGroupName $Config.FrontDoorResourceGroup `
        -Name $Config.FrontDoorProfileName `
        -ErrorAction Stop

    $originInfo = @()
    $originGroups = Get-AzFrontDoorCdnOriginGroup `
        -ResourceGroupName $Config.FrontDoorResourceGroup `
        -ProfileName $Config.FrontDoorProfileName

    foreach ($og in $originGroups) {
        $origins = Get-AzFrontDoorCdnOrigin `
            -ResourceGroupName $Config.FrontDoorResourceGroup `
            -ProfileName $Config.FrontDoorProfileName `
            -OriginGroupName $og.Name

        foreach ($origin in $origins) {
            $originInfo += @{
                OriginGroup = $og.Name
                OriginName  = $origin.Name
                HostName    = $origin.HostName
                Priority    = $origin.Priority
                Weight      = $origin.Weight
            }
            Write-Output "  $($og.Name)/$($origin.Name): Priority=$($origin.Priority)"
        }
    }

    $evidence.Components["FrontDoor"] = @{
        ProvisioningState = $fd.ProvisioningState
        Sku               = $fd.SkuName
        Origins           = $originInfo
    }
}
catch {
    Write-Warning "  Front Door capture failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 4. Key Vault ───────────────────────────────────────────────────────────
Write-Output "[CAPTURE] Key Vault active-region"
try {
    $secret = Get-AzKeyVaultSecret -VaultName $Config.KeyVaultName -Name "active-region" -ErrorAction Stop
    $secretValue = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    $evidence.Components["KeyVault"] = @{
        ActiveRegion = $secretValue
        Updated      = $secret.Updated.ToString("o")
    }
    Write-Output "  active-region: $secretValue (updated: $($secret.Updated))"
}
catch {
    Write-Warning "  Key Vault capture failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 5. Application Gateway (dual-region) ──────────────────────────────────
Write-Output "[CAPTURE] Application Gateway Status"
foreach ($pair in @(
    @{ Name = $Config.AppGwPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.AppGwSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $appgw = Get-AzApplicationGateway -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $evidence.Components["AppGW_$($pair.Label)"] = @{
            Name              = $pair.Name
            ProvisioningState = $appgw.ProvisioningState
            OperationalState  = $appgw.OperationalState
        }
        Write-Output "  $($pair.Label): $($pair.Name) Provisioning=$($appgw.ProvisioningState) Operational=$($appgw.OperationalState)"
    }
    catch {
        $evidence.Components["AppGW_$($pair.Label)"] = @{ Name = $pair.Name; State = "Unreachable" }
        Write-Output "  $($pair.Label): Not reachable"
    }
}

Write-Output ""

# ── 6. Container Apps ─────────────────────────────────────────────────────
Write-Output "[CAPTURE] Container App Status"
foreach ($pair in @(
    @{ Name = $Config.ContainerAppPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.ContainerAppSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $ca = Get-AzContainerApp -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $evidence.Components["ContainerApp_$($pair.Label)"] = @{
            Name              = $pair.Name
            ProvisioningState = $ca.ProvisioningState
        }
        Write-Output "  $($pair.Label): $($pair.Name) State=$($ca.ProvisioningState)"
    }
    catch {
        $evidence.Components["ContainerApp_$($pair.Label)"] = @{ Name = $pair.Name; State = "Unreachable" }
        Write-Output "  $($pair.Label): Not reachable"
    }
}

Write-Output ""

# ── 7. Activity Logs ───────────────────────────────────────────────────────
Write-Output "[CAPTURE] Activity Logs (drill window)"
try {
    foreach ($rg in @($Config.PrimaryResourceGroup, $Config.SecondaryResourceGroup)) {
        $logs = Get-AzActivityLog `
            -ResourceGroupName $rg `
            -StartTime $DrillStartTime `
            -EndTime $DrillEndTime `
            -MaxRecord 50 `
            -ErrorAction Stop

        foreach ($log in $logs) {
            $evidence.ActivityLogs += @{
                Timestamp     = $log.EventTimestamp.ToString("o")
                ResourceGroup = $rg
                Operation     = $log.OperationName.Value
                Status        = $log.Status.Value
                Caller        = $log.Caller
            }
        }
        Write-Output "  $rg : $($logs.Count) events"
    }
}
catch {
    Write-Warning "  Activity log capture failed: $($_.Exception.Message)"
}

# ── Export Evidence ─────────────────────────────────────────────────────────
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$fileName = "dr-drill-evidence-$($Config.Environment)-$timestamp.json"
$filePath = Join-Path $OutputPath $fileName

$evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8

Write-Output ""
Write-Output "============================================"
Write-Output "  Evidence Capture Complete"
Write-Output "============================================"
Write-Output "  Output: $filePath"
Write-Output "  Drill Duration: $($evidence.DrillMetadata.DurationSec)s"
Write-Output "  Measured RTO: ${MeasuredRTO}s"
Write-Output "  Activity Events: $($evidence.ActivityLogs.Count)"
Write-Output ""

$global:DrillEvidence = $evidence
