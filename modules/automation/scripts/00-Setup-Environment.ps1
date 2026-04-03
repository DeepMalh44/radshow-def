<#
.SYNOPSIS
    DR Drill Environment Setup - Configuration & Authentication
.DESCRIPTION
    Sets up environment variables, authenticates via Managed Identity,
    and validates connectivity to all DR-relevant resources.
.NOTES
    Version: 1.0.0
    Project: RAD Showcase
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectName = "radshow",

    [Parameter(Mandatory = $false)]
    [string]$Environment = "prd01",

    [Parameter(Mandatory = $false)]
    [string]$PrimaryRegion = "southcentralus",

    [Parameter(Mandatory = $false)]
    [string]$SecondaryRegion = "northcentralus"
)

$ErrorActionPreference = "Stop"

# ── Configuration ────────────────────────────────────────────────────────────
$global:DrConfig = @{
    ProjectName       = $ProjectName
    Environment       = $Environment
    PrimaryRegion     = $PrimaryRegion
    SecondaryRegion   = $SecondaryRegion
    PrimaryRegionShort  = "scus"
    SecondaryRegionShort = "ncus"

    # Resource Groups
    PrimaryResourceGroup   = "rg-$ProjectName-$Environment-scus"
    SecondaryResourceGroup = "rg-$ProjectName-$Environment-ncus"

    # SQL Managed Instance
    SqlMiPrimaryName       = "sqlmi-$ProjectName-$Environment-scus"
    SqlMiSecondaryName     = "sqlmi-$ProjectName-$Environment-ncus"
    SqlMiFailoverGroupName = "fog-$ProjectName-$Environment"

    # Redis Cache
    RedisPrimaryName       = "redis-$ProjectName-$Environment-scus"
    RedisSecondaryName     = "redis-$ProjectName-$Environment-ncus"

    # Front Door
    FrontDoorProfileName   = "fd-$ProjectName-$Environment"
    FrontDoorResourceGroup = "rg-$ProjectName-$Environment-scus"

    # Key Vault
    KeyVaultName           = "kv-$ProjectName-$Environment"
    KeyVaultResourceGroup  = "rg-$ProjectName-$Environment-scus"

    # Function Apps
    FuncAppPrimaryName     = "func-$ProjectName-$Environment-scus"
    FuncAppSecondaryName   = "func-$ProjectName-$Environment-ncus"

    # API Management
    ApimName               = "apim-$ProjectName-$Environment-scus"
    ApimResourceGroup      = "rg-$ProjectName-$Environment-scus"
}

Write-Output "============================================"
Write-Output "  RAD Showcase DR Drill - Environment Setup"
Write-Output "============================================"
Write-Output ""

# ── Authenticate with Managed Identity ───────────────────────────────────────
Write-Output "[INFO] Authenticating with Managed Identity..."
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    $ctx = Connect-AzAccount -Identity -ErrorAction Stop
    Write-Output "[OK]   Connected as: $($ctx.Context.Account.Id)"
    Write-Output "[OK]   Subscription: $($ctx.Context.Subscription.Name) ($($ctx.Context.Subscription.Id))"
}
catch {
    Write-Error "Failed to authenticate: $($_.Exception.Message)"
    throw
}

# ── Validate Resource Connectivity ───────────────────────────────────────────
Write-Output ""
Write-Output "[INFO] Validating resource connectivity..."

$resources = @(
    @{ Type = "Resource Group (Primary)";   Cmd = { Get-AzResourceGroup -Name $global:DrConfig.PrimaryResourceGroup -ErrorAction Stop } }
    @{ Type = "Resource Group (Secondary)"; Cmd = { Get-AzResourceGroup -Name $global:DrConfig.SecondaryResourceGroup -ErrorAction Stop } }
)

$allOk = $true
foreach ($r in $resources) {
    try {
        & $r.Cmd | Out-Null
        Write-Output "[OK]   $($r.Type)"
    }
    catch {
        Write-Warning "[FAIL] $($r.Type): $($_.Exception.Message)"
        $allOk = $false
    }
}

Write-Output ""
if ($allOk) {
    Write-Output "[SUCCESS] Environment setup complete. All resources reachable."
}
else {
    Write-Warning "[WARN] Some resources could not be reached. Review warnings above."
}

Write-Output ""
Write-Output "Configuration stored in `$global:DrConfig"
Write-Output "Proceed with 01-Check-Health.ps1"
