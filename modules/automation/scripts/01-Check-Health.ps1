<#
.SYNOPSIS
    Pre-Drill Health Check - Validates all DR components before failover
.DESCRIPTION
    Checks health of SQL MI FOG replication, Redis geo-replication,
    Front Door health probe status, and Key Vault accessibility.
.NOTES
    Version: 1.0.0
    Requires: 00-Setup-Environment.ps1 executed first (or pass config)
#>

param(
    [Parameter(Mandatory = $false)]
    [hashtable]$Config = $global:DrConfig
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run 00-Setup-Environment.ps1 first."
    throw
}

$results = @()

Write-Output "============================================"
Write-Output "  RAD Showcase DR Drill - Health Check"
Write-Output "============================================"
Write-Output ""

# ── 1. SQL MI Failover Group ────────────────────────────────────────────────
Write-Output "[CHECK] SQL MI Failover Group: $($Config.SqlMiFailoverGroupName)"
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
    }
    Write-Output "  Role: $($fog.ReplicationRole)"
    Write-Output "  Replication State: $($fog.ReplicationState)"
    Write-Output "  Primary MI: $($fog.ManagedInstanceName)"
    Write-Output "  Partner MI: $($fog.PartnerManagedInstanceId.Split('/')[-1])"
}
catch {
    $results += @{ Component = "SQL MI FOG"; Status = "Error"; Detail = $_.Exception.Message }
    Write-Warning "  SQL MI FOG check failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 2. Redis Geo-Replication ────────────────────────────────────────────────
Write-Output "[CHECK] Redis Geo-Replication"
try {
    $redisPrimary = Get-AzRedisCache -ResourceGroupName $Config.PrimaryResourceGroup -Name $Config.RedisPrimaryName -ErrorAction Stop
    $redisSecondary = Get-AzRedisCache -ResourceGroupName $Config.SecondaryResourceGroup -Name $Config.RedisSecondaryName -ErrorAction Stop

    $results += @{
        Component = "Redis Primary"
        Status    = if ($redisPrimary.ProvisioningState -eq "Succeeded") { "Healthy" } else { "Warning" }
        Detail    = "State=$($redisPrimary.ProvisioningState), Host=$($redisPrimary.HostName)"
    }
    $results += @{
        Component = "Redis Secondary"
        Status    = if ($redisSecondary.ProvisioningState -eq "Succeeded") { "Healthy" } else { "Warning" }
        Detail    = "State=$($redisSecondary.ProvisioningState), Host=$($redisSecondary.HostName)"
    }

    Write-Output "  Primary: $($redisPrimary.HostName) ($($redisPrimary.ProvisioningState))"
    Write-Output "  Secondary: $($redisSecondary.HostName) ($($redisSecondary.ProvisioningState))"
}
catch {
    $results += @{ Component = "Redis"; Status = "Error"; Detail = $_.Exception.Message }
    Write-Warning "  Redis check failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 3. Front Door ───────────────────────────────────────────────────────────
Write-Output "[CHECK] Front Door: $($Config.FrontDoorProfileName)"
try {
    $fd = Get-AzFrontDoorCdnProfile `
        -ResourceGroupName $Config.FrontDoorResourceGroup `
        -Name $Config.FrontDoorProfileName `
        -ErrorAction Stop

    $results += @{
        Component = "Front Door"
        Status    = if ($fd.ProvisioningState -eq "Succeeded") { "Healthy" } else { "Warning" }
        Detail    = "State=$($fd.ProvisioningState), SKU=$($fd.SkuName)"
    }
    Write-Output "  Provisioning State: $($fd.ProvisioningState)"
    Write-Output "  SKU: $($fd.SkuName)"
}
catch {
    $results += @{ Component = "Front Door"; Status = "Error"; Detail = $_.Exception.Message }
    Write-Warning "  Front Door check failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 4. Key Vault ────────────────────────────────────────────────────────────
Write-Output "[CHECK] Key Vault: $($Config.KeyVaultName)"
try {
    $kv = Get-AzKeyVault -VaultName $Config.KeyVaultName -ResourceGroupName $Config.KeyVaultResourceGroup -ErrorAction Stop

    $activeRegion = (Get-AzKeyVaultSecret -VaultName $Config.KeyVaultName -Name "active-region" -ErrorAction SilentlyContinue)
    $activeRegionValue = if ($activeRegion) { $activeRegion.SecretValue | ConvertFrom-SecureString -AsPlainText } else { "not set" }

    $results += @{
        Component = "Key Vault"
        Status    = "Healthy"
        Detail    = "ActiveRegion=$activeRegionValue"
    }
    Write-Output "  Vault URI: $($kv.VaultUri)"
    Write-Output "  Active Region: $activeRegionValue"
}
catch {
    $results += @{ Component = "Key Vault"; Status = "Error"; Detail = $_.Exception.Message }
    Write-Warning "  Key Vault check failed: $($_.Exception.Message)"
}

Write-Output ""

# ── 5. Function Apps ────────────────────────────────────────────────────────
Write-Output "[CHECK] Function Apps"
foreach ($name in @($Config.FuncAppPrimaryName, $Config.FuncAppSecondaryName)) {
    $rg = if ($name -match "scus") { $Config.PrimaryResourceGroup } else { $Config.SecondaryResourceGroup }
    try {
        $app = Get-AzFunctionApp -ResourceGroupName $rg -Name $name -ErrorAction Stop
        $results += @{
            Component = "FuncApp: $name"
            Status    = if ($app.State -eq "Running") { "Healthy" } else { "Warning" }
            Detail    = "State=$($app.State)"
        }
        Write-Output "  $name : $($app.State)"
    }
    catch {
        $results += @{ Component = "FuncApp: $name"; Status = "Error"; Detail = $_.Exception.Message }
        Write-Warning "  $name : $($_.Exception.Message)"
    }
}

Write-Output ""

# ── 6. Application Gateway (dual-region) ──────────────────────────────────
Write-Output "[CHECK] Application Gateways"
foreach ($pair in @(
    @{ Name = $Config.AppGwPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.AppGwSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $appgw = Get-AzApplicationGateway -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $healthy = $appgw.ProvisioningState -eq "Succeeded" -and $appgw.OperationalState -eq "Running"
        $results += @{
            Component = "AppGW ($($pair.Label))"
            Status    = if ($healthy) { "Healthy" } else { "Warning" }
            Detail    = "Provisioning=$($appgw.ProvisioningState), Operational=$($appgw.OperationalState)"
        }
        Write-Output "  $($pair.Name): Provisioning=$($appgw.ProvisioningState) Operational=$($appgw.OperationalState)"
    }
    catch {
        $results += @{ Component = "AppGW ($($pair.Label))"; Status = "Error"; Detail = $_.Exception.Message }
        Write-Warning "  $($pair.Name): $($_.Exception.Message)"
    }
}

Write-Output ""

# ── 7. Container Apps ──────────────────────────────────────────────────────
Write-Output "[CHECK] Container Apps"
foreach ($pair in @(
    @{ Name = $Config.ContainerAppPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.ContainerAppSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $ca = Get-AzContainerApp -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $healthy = $ca.ProvisioningState -eq "Succeeded"
        $results += @{
            Component = "ContainerApp ($($pair.Label))"
            Status    = if ($healthy) { "Healthy" } else { "Warning" }
            Detail    = "State=$($ca.ProvisioningState)"
        }
        Write-Output "  $($pair.Name): $($ca.ProvisioningState)"
    }
    catch {
        $results += @{ Component = "ContainerApp ($($pair.Label))"; Status = "Error"; Detail = $_.Exception.Message }
        Write-Warning "  $($pair.Name): $($_.Exception.Message)"
    }
}

Write-Output ""

# ── 8. API Management ──────────────────────────────────────────────────────
Write-Output "[CHECK] API Management: $($Config.ApimName)"
try {
    $apim = Get-AzApiManagement -ResourceGroupName $Config.ApimResourceGroup -Name $Config.ApimName -ErrorAction Stop

    $results += @{
        Component = "APIM"
        Status    = if ($apim.ProvisioningState -eq "Succeeded") { "Healthy" } else { "Warning" }
        Detail    = "State=$($apim.ProvisioningState), SKU=$($apim.Sku), Regions=$($apim.AdditionalRegions.Count + 1)"
    }
    Write-Output "  Provisioning State: $($apim.ProvisioningState)"
    Write-Output "  SKU: $($apim.Sku)"
    Write-Output "  Gateway URL: $($apim.GatewayUrl)"

    if ($apim.AdditionalRegions.Count -gt 0) {
        foreach ($region in $apim.AdditionalRegions) {
            $regionHealthy = $region.ProvisioningState -eq "Succeeded"
            $results += @{
                Component = "APIM Region: $($region.Location)"
                Status    = if ($regionHealthy) { "Healthy" } else { "Warning" }
                Detail    = "State=$($region.ProvisioningState), Gateway=$($region.GatewayRegionalUrl)"
            }
            Write-Output "  Region: $($region.Location) ($($region.ProvisioningState))"
        }
    }

    # Probe the APIM gateway endpoint
    try {
        $gatewayUrl = "$($apim.GatewayUrl)/status-0123456789abcdef"
        $probeResponse = Invoke-WebRequest -Uri $gatewayUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $results += @{
            Component = "APIM Gateway Probe"
            Status    = if ($probeResponse.StatusCode -eq 200) { "Healthy" } else { "Warning" }
            Detail    = "StatusCode=$($probeResponse.StatusCode)"
        }
        Write-Output "  Gateway Probe: $($probeResponse.StatusCode)"
    }
    catch {
        $results += @{ Component = "APIM Gateway Probe"; Status = "Warning"; Detail = $_.Exception.Message }
        Write-Warning "  Gateway Probe: $($_.Exception.Message)"
    }
}
catch {
    $results += @{ Component = "APIM"; Status = "Error"; Detail = $_.Exception.Message }
    Write-Warning "  APIM check failed: $($_.Exception.Message)"
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "============================================"
Write-Output "  Health Check Summary"
Write-Output "============================================"

$healthy = ($results | Where-Object { $_.Status -eq "Healthy" }).Count
$warnings = ($results | Where-Object { $_.Status -eq "Warning" }).Count
$errors = ($results | Where-Object { $_.Status -eq "Error" }).Count

Write-Output "  Healthy:  $healthy"
Write-Output "  Warnings: $warnings"
Write-Output "  Errors:   $errors"
Write-Output ""

if ($errors -gt 0) {
    Write-Warning "[FAIL] Health check found errors. Fix before proceeding with DR drill."
}
elseif ($warnings -gt 0) {
    Write-Warning "[WARN] Health check has warnings. Review before proceeding."
}
else {
    Write-Output "[SUCCESS] All components healthy. Ready for DR drill."
}

$global:HealthCheckResults = $results
