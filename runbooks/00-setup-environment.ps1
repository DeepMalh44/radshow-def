<#
.SYNOPSIS
    DR Drill Environment Setup - Interactive Operator Script
.DESCRIPTION
    Sets up environment configuration, authenticates interactively (az login or
    service principal), and validates connectivity to all DR-relevant resources.
    This is the operator-facing entry point for workstation-based DR drills.
.NOTES
    Version: 1.0.0
    Project: RAD Showcase
    Tier: 3 (Operator workstation — no region dependency)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectName = "radshow",

    [Parameter(Mandatory = $false)]
    [string]$Environment = "prd01",

    [Parameter(Mandatory = $false)]
    [string]$PrimaryRegion = "southcentralus",

    [Parameter(Mandatory = $false)]
    [string]$SecondaryRegion = "northcentralus",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "",

    [Parameter(Mandatory = $false)]
    [switch]$ServicePrincipal
)

$ErrorActionPreference = "Stop"

# ── Region Short-Name Map (matches radshow-def module conventions) ───────
$regionShortNames = @{
    "southcentralus" = "scus"
    "northcentralus" = "ncus"
    "eastus2"        = "eus2"
    "centralus"      = "cus"
    "westus2"        = "wus2"
    "westeurope"     = "weu"
    "northeurope"    = "neu"
    "swedencentral"  = "swc"
}

$pri = $regionShortNames[$PrimaryRegion]
$sec = $regionShortNames[$SecondaryRegion]

if (-not $pri -or -not $sec) {
    Write-Error "Unknown region. Supported: $($regionShortNames.Keys -join ', ')"
    throw
}

# ── Build Configuration ──────────────────────────────────────────────────
$global:DrConfig = @{
    ProjectName          = $ProjectName
    Environment          = $Environment
    PrimaryRegion        = $PrimaryRegion
    SecondaryRegion      = $SecondaryRegion
    PrimaryRegionShort   = $pri
    SecondaryRegionShort = $sec

    # Resource Groups
    PrimaryResourceGroup   = "rg-$ProjectName-$Environment-$pri"
    SecondaryResourceGroup = "rg-$ProjectName-$Environment-$sec"

    # SQL Managed Instance
    SqlMiPrimaryName       = "sqlmi-$ProjectName-$Environment-$pri"
    SqlMiSecondaryName     = "sqlmi-$ProjectName-$Environment-$sec"
    SqlMiFailoverGroupName = "fog-$ProjectName-$Environment"

    # Redis Cache
    RedisPrimaryName       = "redis-$ProjectName-$Environment-$pri"
    RedisSecondaryName     = "redis-$ProjectName-$Environment-$sec"

    # Front Door
    FrontDoorProfileName   = "fd-$ProjectName-$Environment"
    FrontDoorResourceGroup = "rg-$ProjectName-$Environment-$pri"

    # Key Vault (primary — used for active-region secret + failover password)
    KeyVaultPrimaryName         = "kv-$ProjectName-$Environment-$pri"
    KeyVaultPrimaryResourceGroup = "rg-$ProjectName-$Environment-$pri"
    # Key Vault (secondary — fallback if primary region is down)
    KeyVaultSecondaryName         = "kv-$ProjectName-$Environment-$sec"
    KeyVaultSecondaryResourceGroup = "rg-$ProjectName-$Environment-$sec"

    # Function Apps
    FuncAppPrimaryName     = "func-$ProjectName-$Environment-$pri"
    FuncAppSecondaryName   = "func-$ProjectName-$Environment-$sec"

    # Container Apps
    ContainerAppPrimaryName  = "ca-radshow-api-$Environment-$pri"
    ContainerAppSecondaryName = "ca-radshow-api-$Environment-$sec"

    # APIM
    ApimName = "apim-$ProjectName-$Environment-$pri"

    # Automation Accounts (dual-region for DR resilience)
    AutomationPrimaryName  = "aa-$ProjectName-$Environment-dr-$pri"
    AutomationSecondaryName = "aa-$ProjectName-$Environment-dr-$sec"

    # Front Door endpoint for E2E validation
    FrontDoorEndpoint = "https://fd-$ProjectName-$Environment.azurefd.net"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  RAD Showcase DR Drill - Environment Setup" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Project:         $ProjectName"
Write-Host "  Environment:     $Environment"
Write-Host "  Primary Region:  $PrimaryRegion ($pri)"
Write-Host "  Secondary Region: $SecondaryRegion ($sec)"
Write-Host ""

# ── Authenticate ─────────────────────────────────────────────────────────
Write-Host "[INFO] Authenticating..." -ForegroundColor Yellow
if ($ServicePrincipal) {
    Write-Host "  Using Service Principal authentication"
    $clientId = Read-Host "  Client ID"
    $clientSecret = Read-Host "  Client Secret" -AsSecureString
    $tenantId = Read-Host "  Tenant ID"
    $cred = New-Object System.Management.Automation.PSCredential($clientId, $clientSecret)
    Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId -ErrorAction Stop | Out-Null
}
else {
    Write-Host "  Using interactive authentication (az login)"
    Connect-AzAccount -ErrorAction Stop | Out-Null
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

$ctx = Get-AzContext
Write-Host "[OK]   Connected as: $($ctx.Account.Id)" -ForegroundColor Green
Write-Host "[OK]   Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -ForegroundColor Green

# ── Validate Resource Connectivity ───────────────────────────────────────
Write-Host ""
Write-Host "[INFO] Validating resource connectivity..." -ForegroundColor Yellow

$resources = @(
    @{ Type = "Resource Group (Primary)";   Cmd = { Get-AzResourceGroup -Name $global:DrConfig.PrimaryResourceGroup -ErrorAction Stop } }
    @{ Type = "Resource Group (Secondary)"; Cmd = { Get-AzResourceGroup -Name $global:DrConfig.SecondaryResourceGroup -ErrorAction Stop } }
)

$allOk = $true
foreach ($r in $resources) {
    try {
        & $r.Cmd | Out-Null
        Write-Host "[OK]   $($r.Type)" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] $($r.Type): $($_.Exception.Message)" -ForegroundColor Red
        $allOk = $false
    }
}

Write-Host ""
if ($allOk) {
    Write-Host "[SUCCESS] Environment setup complete. All resources reachable." -ForegroundColor Green
}
else {
    Write-Host "[WARN] Some resources could not be reached. Review failures above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Configuration stored in `$global:DrConfig" -ForegroundColor Gray
Write-Host "Proceed with: .\01-check-health.ps1" -ForegroundColor Gray
