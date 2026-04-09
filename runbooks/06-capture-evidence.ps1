<#
.SYNOPSIS
    Capture DR Drill Evidence - Export logs, metrics, and timestamps
.DESCRIPTION
    Collects evidence from a completed DR drill for compliance and review.
    Exports JSON evidence file + Markdown summary report to local disk.
.NOTES
    Version: 1.0.0
    Tier: 3 (Operator workstation)
    Requires: 00-setup-environment.ps1 executed first
#>

[CmdletBinding()]
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
    Write-Error "Configuration not found. Run .\00-setup-environment.ps1 first."
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

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  RAD Showcase - Evidence Capture" -ForegroundColor Cyan
Write-Host "  Drill Window: $($DrillStartTime.ToString('HH:mm:ss')) - $($DrillEndTime.ToString('HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. SQL MI FOG Status Snapshot ───────────────────────────────────────
Write-Host "[CAPTURE] SQL MI Failover Group Status" -ForegroundColor Yellow
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
            Write-Host "  $($pair.Label): Role=$($fog.ReplicationRole), State=$($fog.ReplicationState)" -ForegroundColor Green
        }
        catch {
            Write-Host "  $($pair.Label): Not reachable" -ForegroundColor Yellow
        }
    }
}
catch {
    Write-Host "  SQL MI capture failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 2. Redis Status ─────────────────────────────────────────────────────
Write-Host "[CAPTURE] Redis Cache Status" -ForegroundColor Yellow
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
        Write-Host "  $($pair.Label): $($redis.ProvisioningState)" -ForegroundColor Green
    }
    catch {
        Write-Host "  $($pair.Label): Not reachable" -ForegroundColor Yellow
    }
}

Write-Host ""

# ── 3. Front Door Status + Origin Priorities ────────────────────────────
Write-Host "[CAPTURE] Front Door Status" -ForegroundColor Yellow
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
            Write-Host "  $($og.Name)/$($origin.Name): Priority=$($origin.Priority)" -ForegroundColor Green
        }
    }

    $evidence.Components["FrontDoor"] = @{
        ProvisioningState = $fd.ProvisioningState
        Sku               = $fd.SkuName
        Origins           = $originInfo
    }
}
catch {
    Write-Host "  Front Door capture failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 4. Key Vault (both vaults) ──────────────────────────────────────────
Write-Host "[CAPTURE] Key Vault active-region (both vaults)" -ForegroundColor Yellow
foreach ($kvName in @($Config.KeyVaultPrimaryName, $Config.KeyVaultSecondaryName)) {
    try {
        $secret = Get-AzKeyVaultSecret -VaultName $kvName -Name "active-region" -ErrorAction Stop
        $secretValue = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        $evidence.Components["KeyVault_$kvName"] = @{
            ActiveRegion = $secretValue
            Updated      = $secret.Updated.ToString("o")
        }
        Write-Host "  $kvName : active-region=$secretValue (updated: $($secret.Updated))" -ForegroundColor Green
    }
    catch {
        Write-Host "  $kvName : capture failed" -ForegroundColor Yellow
    }
}

Write-Host ""

# ── 5. Container Apps ─────────────────────────────────────────────────
Write-Host "[CAPTURE] Container App Status" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.ContainerAppPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.ContainerAppSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $ca = Get-AzContainerApp -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $evidence.Components["ContainerApp_$($pair.Label)"] = @{
            Name              = $pair.Name
            ProvisioningState = $ca.ProvisioningState
            RunningStatus     = $ca.RunningStatus
        }
        Write-Host "  $($pair.Label): $($pair.Name) State=$($ca.ProvisioningState)" -ForegroundColor Green
    }
    catch {
        $evidence.Components["ContainerApp_$($pair.Label)"] = @{
            Name  = $pair.Name
            State = "Unreachable"
        }
        Write-Host "  $($pair.Label): Not reachable" -ForegroundColor Yellow
    }
}

Write-Host ""

# ── 6. Application Gateways (dual-region) ──────────────────────────────
Write-Host "[CAPTURE] Application Gateway Status" -ForegroundColor Yellow
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
        Write-Host "  $($pair.Label): $($pair.Name) Provisioning=$($appgw.ProvisioningState) Operational=$($appgw.OperationalState)" -ForegroundColor Green
    }
    catch {
        $evidence.Components["AppGW_$($pair.Label)"] = @{
            Name  = $pair.Name
            State = "Unreachable"
        }
        Write-Host "  $($pair.Label): Not reachable" -ForegroundColor Yellow
    }
}

Write-Host ""

# ── 7. Activity Logs ───────────────────────────────────────────────────
Write-Host "[CAPTURE] Activity Logs (drill window)" -ForegroundColor Yellow
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
        Write-Host "  $rg : $($logs.Count) events captured" -ForegroundColor Green
    }
}
catch {
    Write-Host "  Activity log capture failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 8. Automation Account Status (dual-region) ─────────────────────────
Write-Host "[CAPTURE] Automation Accounts (dual-region)" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.AutomationPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.AutomationSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $aa = Get-AzAutomationAccount -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $evidence.Components["Automation_$($pair.Label)"] = @{
            Name  = $pair.Name
            State = "Accessible"
        }
        Write-Host "  $($pair.Label): $($pair.Name) [OK]" -ForegroundColor Green
    }
    catch {
        $evidence.Components["Automation_$($pair.Label)"] = @{
            Name  = $pair.Name
            State = "Unreachable"
        }
        Write-Host "  $($pair.Label): Not reachable" -ForegroundColor Yellow
    }
}

Write-Host ""

# ── Export JSON Evidence ────────────────────────────────────────────────
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonFile = Join-Path $OutputPath "dr-drill-evidence-$($Config.Environment)-$timestamp.json"
$evidence | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8
Write-Host "[EXPORT] JSON evidence: $jsonFile" -ForegroundColor Green

# ── Export Markdown Summary ─────────────────────────────────────────────
$mdFile = Join-Path $OutputPath "dr-drill-report-$($Config.Environment)-$timestamp.md"
$md = @"
# DR Drill Report — $($Config.ProjectName) $($Config.Environment)

| Field | Value |
|---|---|
| Drill Type | $DrillType |
| Start Time | $($DrillStartTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC |
| End Time | $($DrillEndTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC |
| Duration | $([math]::Round(($DrillEndTime - $DrillStartTime).TotalMinutes, 1)) min |
| Measured RTO | ${MeasuredRTO}s |
| Captured By | $((Get-AzContext).Account.Id) |

## Component Status

| Component | Detail |
|---|---|
"@

foreach ($key in $evidence.Components.Keys) {
    $comp = $evidence.Components[$key]
    $detail = ($comp.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
    $md += "| $key | $detail |`n"
}

$md += @"

## Activity Log Summary

| Time | Resource Group | Operation | Status |
|---|---|---|---|
"@

foreach ($log in ($evidence.ActivityLogs | Select-Object -First 20)) {
    $md += "| $($log.Timestamp) | $($log.ResourceGroup) | $($log.Operation) | $($log.Status) |`n"
}

$md | Out-File -FilePath $mdFile -Encoding UTF8
Write-Host "[EXPORT] Markdown report: $mdFile" -ForegroundColor Green

$global:DrillEvidence = $evidence

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Evidence Capture Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  JSON: $jsonFile"
Write-Host "  Report: $mdFile"
Write-Host ""
