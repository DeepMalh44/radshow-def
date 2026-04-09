<#
.SYNOPSIS
    Pre-Drill Health Check with Go/No-Go Gate
.DESCRIPTION
    Validates all DR components before failover and presents an interactive
    go/no-go prompt. Blocks drill execution if critical failures detected.
.NOTES
    Version: 1.0.0
    Tier: 3 (Operator workstation)
    Requires: 00-setup-environment.ps1 executed first
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [hashtable]$Config = $global:DrConfig,

    [Parameter(Mandatory = $false)]
    [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run .\00-setup-environment.ps1 first."
    throw
}

$results = @()

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  RAD Showcase DR Drill - Pre-Drill Health" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. SQL MI Failover Group ────────────────────────────────────────────
Write-Host "[CHECK] SQL MI Failover Group: $($Config.SqlMiFailoverGroupName)" -ForegroundColor Yellow
try {
    $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
        -ResourceGroupName $Config.PrimaryResourceGroup `
        -Location $Config.PrimaryRegion `
        -Name $Config.SqlMiFailoverGroupName `
        -ErrorAction Stop

    $fogHealthy = $fog.ReplicationState -eq "CATCH_UP"
    $results += @{
        Component = "SQL MI FOG"
        Status    = if ($fogHealthy) { "Healthy" } else { "Warning" }
        Detail    = "Role=$($fog.ReplicationRole), State=$($fog.ReplicationState)"
        Critical  = $true
    }
    $color = if ($fogHealthy) { "Green" } else { "Yellow" }
    Write-Host "  Role: $($fog.ReplicationRole)" -ForegroundColor $color
    Write-Host "  Replication State: $($fog.ReplicationState)" -ForegroundColor $color
    Write-Host "  Primary MI: $($fog.ManagedInstanceName)"
    Write-Host "  Partner MI: $($fog.PartnerManagedInstanceId.Split('/')[-1])"
}
catch {
    $results += @{ Component = "SQL MI FOG"; Status = "Error"; Detail = $_.Exception.Message; Critical = $true }
    Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 2. Redis Geo-Replication ────────────────────────────────────────────
Write-Host "[CHECK] Redis Geo-Replication" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.RedisPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.RedisSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $redis = Get-AzRedisCache -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $healthy = $redis.ProvisioningState -eq "Succeeded"
        $results += @{
            Component = "Redis ($($pair.Label))"
            Status    = if ($healthy) { "Healthy" } else { "Warning" }
            Detail    = "State=$($redis.ProvisioningState), Host=$($redis.HostName)"
            Critical  = $false
        }
        $color = if ($healthy) { "Green" } else { "Yellow" }
        Write-Host "  $($pair.Label): $($redis.HostName) ($($redis.ProvisioningState))" -ForegroundColor $color
    }
    catch {
        $results += @{ Component = "Redis ($($pair.Label))"; Status = "Error"; Detail = $_.Exception.Message; Critical = $false }
        Write-Host "  $($pair.Label): [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# ── 3. Front Door ───────────────────────────────────────────────────────
Write-Host "[CHECK] Front Door: $($Config.FrontDoorProfileName)" -ForegroundColor Yellow
try {
    $fd = Get-AzFrontDoorCdnProfile `
        -ResourceGroupName $Config.FrontDoorResourceGroup `
        -Name $Config.FrontDoorProfileName `
        -ErrorAction Stop

    $healthy = $fd.ProvisioningState -eq "Succeeded"
    $results += @{
        Component = "Front Door"
        Status    = if ($healthy) { "Healthy" } else { "Warning" }
        Detail    = "State=$($fd.ProvisioningState), SKU=$($fd.SkuName)"
        Critical  = $true
    }
    $color = if ($healthy) { "Green" } else { "Yellow" }
    Write-Host "  Provisioning State: $($fd.ProvisioningState)" -ForegroundColor $color
    Write-Host "  SKU: $($fd.SkuName)"

    # List current origin priorities
    $originGroups = Get-AzFrontDoorCdnOriginGroup `
        -ResourceGroupName $Config.FrontDoorResourceGroup `
        -ProfileName $Config.FrontDoorProfileName

    foreach ($og in $originGroups) {
        $origins = Get-AzFrontDoorCdnOrigin `
            -ResourceGroupName $Config.FrontDoorResourceGroup `
            -ProfileName $Config.FrontDoorProfileName `
            -OriginGroupName $og.Name
        foreach ($origin in $origins) {
            Write-Host "  Origin: $($origin.Name) | Priority=$($origin.Priority) | Host=$($origin.HostName)"
        }
    }
}
catch {
    $results += @{ Component = "Front Door"; Status = "Error"; Detail = $_.Exception.Message; Critical = $true }
    Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 4. Key Vault (both regions) ─────────────────────────────────────────
Write-Host "[CHECK] Key Vaults (dual-region)" -ForegroundColor Yellow
foreach ($kv in @(
    @{ Name = $Config.KeyVaultPrimaryName; RG = $Config.KeyVaultPrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.KeyVaultSecondaryName; RG = $Config.KeyVaultSecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        Get-AzKeyVault -VaultName $kv.Name -ResourceGroupName $kv.RG -ErrorAction Stop | Out-Null
        $results += @{
            Component = "Key Vault ($($kv.Label))"
            Status    = "Healthy"
            Detail    = "$($kv.Name) accessible"
            Critical  = ($kv.Label -eq "Primary")
        }
        Write-Host "  $($kv.Label): $($kv.Name) [OK]" -ForegroundColor Green
    }
    catch {
        $results += @{ Component = "Key Vault ($($kv.Label))"; Status = "Error"; Detail = $_.Exception.Message; Critical = ($kv.Label -eq "Primary") }
        Write-Host "  $($kv.Label): [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Check active-region secret
try {
    $secret = Get-AzKeyVaultSecret -VaultName $Config.KeyVaultPrimaryName -Name "active-region" -ErrorAction Stop
    $activeRegionValue = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    Write-Host "  active-region: $activeRegionValue"
}
catch {
    Write-Host "  active-region secret: not readable (may need RBAC)" -ForegroundColor Yellow
}

Write-Host ""

# ── 5. Function Apps ────────────────────────────────────────────────────
Write-Host "[CHECK] Function Apps" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.FuncAppPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.FuncAppSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $app = Get-AzFunctionApp -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $running = $app.State -eq "Running"
        $results += @{
            Component = "FuncApp ($($pair.Label))"
            Status    = if ($running) { "Healthy" } else { "Warning" }
            Detail    = "State=$($app.State)"
            Critical  = $false
        }
        $color = if ($running) { "Green" } else { "Yellow" }
        Write-Host "  $($pair.Name): $($app.State)" -ForegroundColor $color
    }
    catch {
        $results += @{ Component = "FuncApp ($($pair.Label))"; Status = "Error"; Detail = $_.Exception.Message; Critical = $false }
        Write-Host "  $($pair.Name): [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# ── 6. Automation Accounts (dual-region) ────────────────────────────────
Write-Host "[CHECK] Automation Accounts (dual-region)" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.AutomationPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.AutomationSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $aa = Get-AzAutomationAccount -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $results += @{
            Component = "Automation ($($pair.Label))"
            Status    = "Healthy"
            Detail    = "$($pair.Name) accessible"
            Critical  = $false
        }
        Write-Host "  $($pair.Label): $($pair.Name) [OK]" -ForegroundColor Green
    }
    catch {
        $results += @{ Component = "Automation ($($pair.Label))"; Status = "Error"; Detail = $_.Exception.Message; Critical = $false }
        Write-Host "  $($pair.Label): [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# ── 7. Container Apps ──────────────────────────────────────────────────
Write-Host "[CHECK] Container Apps" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.ContainerAppPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.ContainerAppSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $ca = Get-AzContainerApp -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $running = $ca.ProvisioningState -eq "Succeeded"
        $results += @{
            Component = "ContainerApp ($($pair.Label))"
            Status    = if ($running) { "Healthy" } else { "Warning" }
            Detail    = "State=$($ca.ProvisioningState), RunningStatus=$($ca.RunningStatus)"
            Critical  = $false
        }
        $color = if ($running) { "Green" } else { "Yellow" }
        Write-Host "  $($pair.Name): $($ca.ProvisioningState)" -ForegroundColor $color
    }
    catch {
        $results += @{ Component = "ContainerApp ($($pair.Label))"; Status = "Error"; Detail = $_.Exception.Message; Critical = $false }
        Write-Host "  $($pair.Name): [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Summary ─────────────────────────────────────────────────────────────
$healthy = ($results | Where-Object { $_.Status -eq "Healthy" }).Count
$warnings = ($results | Where-Object { $_.Status -eq "Warning" }).Count
$errors = ($results | Where-Object { $_.Status -eq "Error" }).Count
$critErrors = ($results | Where-Object { $_.Status -eq "Error" -and $_.Critical }).Count

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Health Check Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Healthy:  $healthy" -ForegroundColor Green
Write-Host "  Warnings: $warnings" -ForegroundColor Yellow
Write-Host "  Errors:   $errors" -ForegroundColor $(if ($errors -gt 0) { "Red" } else { "Green" })
Write-Host ""

$global:HealthCheckResults = $results

if ($critErrors -gt 0) {
    Write-Host "[NO-GO] Critical components have errors. DR drill should NOT proceed." -ForegroundColor Red
    Write-Host "  Fix critical issues before retrying." -ForegroundColor Red
    return
}

if ($errors -gt 0) {
    Write-Host "[CAUTION] Non-critical errors detected. Drill can proceed with degraded scope." -ForegroundColor Yellow
}
else {
    Write-Host "[GO] All checks passed." -ForegroundColor Green
}

if (-not $NoPrompt) {
    Write-Host ""
    $proceed = Read-Host "Proceed with DR drill? [Y/N]"
    if ($proceed -ne "Y") {
        Write-Host "Drill aborted by operator." -ForegroundColor Yellow
        return
    }
    Write-Host "[OK] Operator confirmed. Proceed with failover script." -ForegroundColor Green
}
