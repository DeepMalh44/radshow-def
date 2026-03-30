<#
.SYNOPSIS
    Post-Failover Validation with End-to-End CRUD Test
.DESCRIPTION
    Validates all components after failover/failback and runs an E2E CRUD test
    against the Product Inventory API via Front Door to verify the full data path.
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
    [ValidateSet("failover", "failback")]
    [string]$OperationType = "failover",

    [Parameter(Mandatory = $false)]
    [switch]$SkipCrudTest
)

$ErrorActionPreference = "Stop"

if (-not $Config) {
    Write-Error "Configuration not found. Run .\00-setup-environment.ps1 first."
    throw
}

$validationResults = @()
$expectedPrimary = if ($OperationType -eq "failover") { $Config.SecondaryRegion } else { $Config.PrimaryRegion }
$expectedPrimaryShort = if ($OperationType -eq "failover") { $Config.SecondaryRegionShort } else { $Config.PrimaryRegionShort }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Post-$OperationType Validation" -ForegroundColor Cyan
Write-Host "  Expected Active Region: $expectedPrimary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. SQL MI FOG Role Validation ───────────────────────────────────────
Write-Host "[VALIDATE] SQL MI Failover Group" -ForegroundColor Yellow
try {
    $expectedPrimaryRG = if ($OperationType -eq "failover") { $Config.SecondaryResourceGroup } else { $Config.PrimaryResourceGroup }

    $fog = Get-AzSqlDatabaseInstanceFailoverGroup `
        -ResourceGroupName $expectedPrimaryRG `
        -Location $expectedPrimary `
        -Name $Config.SqlMiFailoverGroupName `
        -ErrorAction Stop

    $roleCorrect = $fog.ReplicationRole -eq "Primary"
    $validationResults += @{
        Check  = "SQL MI FOG Role"
        Pass   = $roleCorrect
        Detail = "Role=$($fog.ReplicationRole), Expected=Primary at $expectedPrimary"
    }

    if ($roleCorrect) {
        Write-Host "  [PASS] $expectedPrimary is Primary" -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] Expected Primary at $expectedPrimary, got $($fog.ReplicationRole)" -ForegroundColor Red
    }
    Write-Host "  Replication State: $($fog.ReplicationState)"
}
catch {
    $validationResults += @{ Check = "SQL MI FOG Role"; Pass = $false; Detail = $_.Exception.Message }
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 2. Redis Connectivity ──────────────────────────────────────────────
Write-Host "[VALIDATE] Redis Cache" -ForegroundColor Yellow
foreach ($pair in @(
    @{ Name = $Config.RedisPrimaryName; RG = $Config.PrimaryResourceGroup; Label = "Primary" }
    @{ Name = $Config.RedisSecondaryName; RG = $Config.SecondaryResourceGroup; Label = "Secondary" }
)) {
    try {
        $redis = Get-AzRedisCache -ResourceGroupName $pair.RG -Name $pair.Name -ErrorAction Stop
        $healthy = $redis.ProvisioningState -eq "Succeeded"
        $validationResults += @{
            Check  = "Redis ($($pair.Label))"
            Pass   = $healthy
            Detail = "State=$($redis.ProvisioningState)"
        }
        $color = if ($healthy) { "Green" } else { "Red" }
        Write-Host "  $($pair.Label): $($redis.ProvisioningState) $(if ($healthy) {'[PASS]'} else {'[FAIL]'})" -ForegroundColor $color
    }
    catch {
        $validationResults += @{ Check = "Redis ($($pair.Label))"; Pass = $false; Detail = $_.Exception.Message }
        Write-Host "  $($pair.Label): [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# ── 3. Front Door Origin Priorities ────────────────────────────────────
Write-Host "[VALIDATE] Front Door Origin Priorities" -ForegroundColor Yellow
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
            $isExpectedPrimary = $origin.HostName -match $expectedPrimaryShort
            $expectedPrio = if ($isExpectedPrimary) { 1 } else { 2 }
            $prioCorrect = $origin.Priority -eq $expectedPrio

            $validationResults += @{
                Check  = "FD Origin: $($origin.Name)"
                Pass   = $prioCorrect
                Detail = "Priority=$($origin.Priority), Expected=$expectedPrio"
            }
            $color = if ($prioCorrect) { "Green" } else { "Red" }
            Write-Host "  $($origin.Name): Priority=$($origin.Priority) $(if ($prioCorrect) {'[PASS]'} else {'[FAIL]'})" -ForegroundColor $color
        }
    }
}
catch {
    $validationResults += @{ Check = "Front Door Origins"; Pass = $false; Detail = $_.Exception.Message }
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 4. Key Vault active-region (both vaults) ──────────────────────────
Write-Host "[VALIDATE] Key Vault active-region" -ForegroundColor Yellow
foreach ($kvName in @($Config.KeyVaultPrimaryName, $Config.KeyVaultSecondaryName)) {
    try {
        $secret = Get-AzKeyVaultSecret -VaultName $kvName -Name "active-region" -ErrorAction Stop
        $secretValue = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
        $regionCorrect = $secretValue -eq $expectedPrimary

        $validationResults += @{
            Check  = "KV active-region ($kvName)"
            Pass   = $regionCorrect
            Detail = "Value=$secretValue, Expected=$expectedPrimary"
        }
        $color = if ($regionCorrect) { "Green" } else { "Red" }
        Write-Host "  $kvName : $secretValue $(if ($regionCorrect) {'[PASS]'} else {'[FAIL]'})" -ForegroundColor $color
    }
    catch {
        $validationResults += @{ Check = "KV active-region ($kvName)"; Pass = $false; Detail = $_.Exception.Message }
        Write-Host "  $kvName : [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# ── 5. Function App Health ─────────────────────────────────────────────
Write-Host "[VALIDATE] Function App Status" -ForegroundColor Yellow
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
    $color = if ($running) { "Green" } else { "Red" }
    Write-Host "  $expectedActiveName : $($app.State) $(if ($running) {'[PASS]'} else {'[FAIL]'})" -ForegroundColor $color
}
catch {
    $validationResults += @{ Check = "Active Function App"; Pass = $false; Detail = $_.Exception.Message }
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# ── 6. E2E CRUD Test via Front Door ────────────────────────────────────
if (-not $SkipCrudTest) {
    Write-Host "[VALIDATE] E2E CRUD Test via Front Door" -ForegroundColor Yellow
    $apiBase = "$($Config.FrontDoorEndpoint)/api"
    $testProductId = $null

    # CREATE
    try {
        $body = @{
            Name            = "DR-Drill-Test-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Description     = "Auto-created by DR validation script"
            Price           = 9.99
            QuantityInStock = 1
        } | ConvertTo-Json

        $createResp = Invoke-RestMethod -Uri "$apiBase/products" -Method POST -Body $body -ContentType "application/json" -ErrorAction Stop
        $testProductId = $createResp.id
        $validationResults += @{ Check = "CRUD: Create"; Pass = ($null -ne $testProductId); Detail = "Created product $testProductId" }
        Write-Host "  CREATE: Product $testProductId [PASS]" -ForegroundColor Green

        # READ
        $readResp = Invoke-RestMethod -Uri "$apiBase/products/$testProductId" -Method GET -ErrorAction Stop
        $readOk = $readResp.id -eq $testProductId
        $regionInfo = if ($readResp.LastUpdatedRegion) { " (region: $($readResp.LastUpdatedRegion))" } else { "" }
        $validationResults += @{ Check = "CRUD: Read"; Pass = $readOk; Detail = "Read product $testProductId$regionInfo" }
        Write-Host "  READ:   Product $testProductId$regionInfo [PASS]" -ForegroundColor Green

        # UPDATE
        $updateBody = @{ Price = 19.99 } | ConvertTo-Json
        $updateResp = Invoke-RestMethod -Uri "$apiBase/products/$testProductId" -Method PUT -Body $updateBody -ContentType "application/json" -ErrorAction Stop
        $validationResults += @{ Check = "CRUD: Update"; Pass = $true; Detail = "Updated price to 19.99" }
        Write-Host "  UPDATE: Price -> 19.99 [PASS]" -ForegroundColor Green

        # DELETE
        Invoke-RestMethod -Uri "$apiBase/products/$testProductId" -Method DELETE -ErrorAction Stop
        $validationResults += @{ Check = "CRUD: Delete"; Pass = $true; Detail = "Deleted product $testProductId" }
        Write-Host "  DELETE: Product $testProductId [PASS]" -ForegroundColor Green
    }
    catch {
        $validationResults += @{ Check = "CRUD Test"; Pass = $false; Detail = $_.Exception.Message }
        Write-Host "  [FAIL] CRUD test failed: $($_.Exception.Message)" -ForegroundColor Red

        # Cleanup attempt
        if ($testProductId) {
            try { Invoke-RestMethod -Uri "$apiBase/products/$testProductId" -Method DELETE -ErrorAction SilentlyContinue } catch {}
        }
    }
}
else {
    Write-Host "[SKIP] E2E CRUD Test (--SkipCrudTest)" -ForegroundColor Gray
}

# ── Summary ─────────────────────────────────────────────────────────────
$passed = ($validationResults | Where-Object { $_.Pass }).Count
$failed = ($validationResults | Where-Object { -not $_.Pass }).Count
$total = $validationResults.Count

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Validation Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Passed: $passed / $total" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
Write-Host "  Failed: $failed / $total" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""

foreach ($vr in $validationResults) {
    $color = if ($vr.Pass) { "Green" } else { "Red" }
    $icon = if ($vr.Pass) { "PASS" } else { "FAIL" }
    Write-Host "  [$icon] $($vr.Check): $($vr.Detail)" -ForegroundColor $color
}

$global:ValidationResults = $validationResults

Write-Host ""
Write-Host "Results stored in `$global:ValidationResults" -ForegroundColor Gray
Write-Host "Proceed with: .\06-capture-evidence.ps1" -ForegroundColor Gray
