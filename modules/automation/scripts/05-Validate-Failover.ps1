<#
.SYNOPSIS
    Post-Failover Validation - Verifies system health after DR operation
.DESCRIPTION
    Validates that all components are healthy after a failover or failback:
    - SQL MI FOG role & replication state
    - Redis connectivity
    - Front Door routing
    - Function App health endpoints
    - Key Vault active-region consistency
.NOTES
    Version: 1.0.0
    Requires: 00-Setup-Environment.ps1 executed first
#>

param(
    [Parameter(Mandatory = $false)]
    [hashtable]$Config = $global:DrConfig,

    [Parameter(Mandatory = $false)]
    [ValidateSet("failover", "failback")]
    [string]$OperationType = "failover"
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run 00-Setup-Environment.ps1 first."
    throw
}

$validationResults = @()
$expectedPrimary = if ($OperationType -eq "failover") { $Config.SecondaryRegion } else { $Config.PrimaryRegion }

Write-Output "============================================"
Write-Output "  RAD Showcase - Post-$OperationType Validation"
Write-Output "  Expected Primary: $expectedPrimary"
Write-Output "============================================"
Write-Output ""

# ── 1. SQL MI FOG Role Validation ───────────────────────────────────────────
Write-Output "[VALIDATE] SQL MI Failover Group"
try {
    $expectedPrimaryRG = if ($OperationType -eq "failover") { $Config.SecondaryResourceGroup } else { $Config.PrimaryResourceGroup }
    $expectedPrimaryLoc = $expectedPrimary

    $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
        -ResourceGroupName $expectedPrimaryRG `
        -Location $expectedPrimaryLoc `
        -Name $Config.SqlMiFailoverGroupName `
        -ErrorAction Stop

    $roleCorrect = $fog.ReplicationRole -eq "Primary"
    $validationResults += @{
        Check  = "SQL MI FOG Role"
        Pass   = $roleCorrect
        Detail = "Role=$($fog.ReplicationRole), Expected=Primary"
    }

    if ($roleCorrect) {
        Write-Output "  [PASS] $expectedPrimaryLoc is Primary"
    }
    else {
        Write-Warning "  [FAIL] Expected Primary role at $expectedPrimaryLoc, got $($fog.ReplicationRole)"
    }

    Write-Output "  Replication State: $($fog.ReplicationState)"
}
catch {
    $validationResults += @{ Check = "SQL MI FOG Role"; Pass = $false; Detail = $_.Exception.Message }
    Write-Warning "  [FAIL] $($_.Exception.Message)"
}

Write-Output ""

# ── 2. Redis Connectivity ──────────────────────────────────────────────────
Write-Output "[VALIDATE] Redis Cache"
foreach ($pair in @(
    @{ Name = $Config.RedisPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.RedisSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $redis = Get-AzRedisCache -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $healthy = $redis.ProvisioningState -eq "Succeeded"

        $validationResults += @{
            Check  = "Redis $($pair.Label)"
            Pass   = $healthy
            Detail = "State=$($redis.ProvisioningState)"
        }
        Write-Output "  $($pair.Label): $($redis.ProvisioningState) $(if ($healthy) {'[PASS]'} else {'[FAIL]'})"
    }
    catch {
        $validationResults += @{ Check = "Redis $($pair.Label)"; Pass = $false; Detail = $_.Exception.Message }
        Write-Warning "  $($pair.Label): [FAIL] $($_.Exception.Message)"
    }
}

Write-Output ""

# ── 3. Front Door Origin Priorities ────────────────────────────────────────
Write-Output "[VALIDATE] Front Door Origin Priorities"
try {
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
            $isExpectedPrimary = $origin.HostName -match $(
                if ($OperationType -eq "failover") { $Config.SecondaryRegionShort } else { $Config.PrimaryRegionShort }
            )

            $expectedPrio = if ($isExpectedPrimary) { 1 } else { 2 }
            $prioCorrect = $origin.Priority -eq $expectedPrio

            $validationResults += @{
                Check  = "FD Origin: $($origin.Name)"
                Pass   = $prioCorrect
                Detail = "Priority=$($origin.Priority), Expected=$expectedPrio"
            }
            Write-Output "  $($origin.Name): Priority=$($origin.Priority) $(if ($prioCorrect) {'[PASS]'} else {'[FAIL]'})"
        }
    }
}
catch {
    $validationResults += @{ Check = "Front Door Origins"; Pass = $false; Detail = $_.Exception.Message }
    Write-Warning "  [FAIL] $($_.Exception.Message)"
}

Write-Output ""

# ── 4. Key Vault active-region ─────────────────────────────────────────────
Write-Output "[VALIDATE] Key Vault active-region"
try {
    $secret = Get-AzKeyVaultSecret -VaultName $Config.KeyVaultName -Name "active-region" -ErrorAction Stop
    $secretValue = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
    $regionCorrect = $secretValue -eq $expectedPrimary

    $validationResults += @{
        Check  = "KV active-region"
        Pass   = $regionCorrect
        Detail = "Value=$secretValue, Expected=$expectedPrimary"
    }

    if ($regionCorrect) {
        Write-Output "  [PASS] active-region=$secretValue"
    }
    else {
        Write-Warning "  [FAIL] active-region=$secretValue, expected $expectedPrimary"
    }
}
catch {
    $validationResults += @{ Check = "KV active-region"; Pass = $false; Detail = $_.Exception.Message }
    Write-Warning "  [FAIL] $($_.Exception.Message)"
}

Write-Output ""

# ── 5. Function App Health ─────────────────────────────────────────────────
Write-Output "[VALIDATE] Function App Status"
$expectedActiveName = if ($OperationType -eq "failover") { $Config.FuncAppSecondaryName } else { $Config.FuncAppPrimaryName }
$expectedActiveRG = if ($OperationType -eq "failover") { $Config.SecondaryResourceGroup } else { $Config.PrimaryResourceGroup }

try {
    $app = Get-AzFunctionApp -ResourceGroupName $expectedActiveRG -Name $expectedActiveName -ErrorAction Stop
    $running = $app.State -eq "Running"

    $validationResults += @{
        Check  = "Active Function App"
        Pass   = $running
        Detail = "$expectedActiveName State=$($app.State)"
    }
    Write-Output "  $expectedActiveName : $($app.State) $(if ($running) {'[PASS]'} else {'[FAIL]'})"
}
catch {
    $validationResults += @{ Check = "Active Function App"; Pass = $false; Detail = $_.Exception.Message }
    Write-Warning "  [FAIL] $($_.Exception.Message)"
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "============================================"
Write-Output "  Validation Summary"
Write-Output "============================================"

$passed = ($validationResults | Where-Object { $_.Pass }).Count
$failed = ($validationResults | Where-Object { -not $_.Pass }).Count
$total = $validationResults.Count

Write-Output "  Passed: $passed / $total"
Write-Output "  Failed: $failed / $total"
Write-Output ""

if ($failed -eq 0) {
    Write-Output "[SUCCESS] All post-$OperationType validations passed."
}
else {
    Write-Warning "[FAIL] $failed validation(s) failed. Review details above."
    foreach ($f in ($validationResults | Where-Object { -not $_.Pass })) {
        Write-Warning "  - $($f.Check): $($f.Detail)"
    }
}

$global:ValidationResults = $validationResults
