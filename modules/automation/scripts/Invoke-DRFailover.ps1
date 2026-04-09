<#
.SYNOPSIS
    Invoke-DRFailover - Automation Runbook for alert-triggered failover
.DESCRIPTION
    Azure Automation runbook that can be invoked via webhook from Azure Monitor alerts
    or manually. Orchestrates the full DR failover sequence using the modular scripts.
.PARAMETER WebhookData
    JSON payload from Azure Monitor alert (Common Alert Schema)
.PARAMETER FailoverType
    'Planned' for graceful, 'Forced' for emergency (AllowDataLoss)
.PARAMETER Action
    'failover' to switch to secondary, 'failback' to return to primary
.NOTES
    Version: 1.0.0
    Deploy as Azure Automation Runbook
#>

param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Planned", "Forced")]
    [string]$FailoverType = "Planned",

    [Parameter(Mandatory = $false)]
    [ValidateSet("failover", "failback")]
    [string]$Action = "failover"
)

$ErrorActionPreference = "Stop"

# ── Configuration ─────────────────────────────────────────────────────────
$ProjectName    = Get-AutomationVariable -Name "ProjectName"    -ErrorAction SilentlyContinue
$Environment    = Get-AutomationVariable -Name "Environment"    -ErrorAction SilentlyContinue
$PrimaryRegion  = Get-AutomationVariable -Name "PrimaryRegion"  -ErrorAction SilentlyContinue
$SecondaryRegion = Get-AutomationVariable -Name "SecondaryRegion" -ErrorAction SilentlyContinue

if (-not $ProjectName)    { $ProjectName    = "radshow" }
if (-not $Environment)    { $Environment    = "prd01" }
if (-not $PrimaryRegion)  { $PrimaryRegion  = "southcentralus" }
if (-not $SecondaryRegion) { $SecondaryRegion = "northcentralus" }

$drillStart = Get-Date

Write-Output "============================================"
Write-Output "  RAD Showcase - Automation Runbook"
Write-Output "  Action: $Action | Type: $FailoverType"
Write-Output "  Started: $($drillStart.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "============================================"

# ── Parse webhook (if alert-triggered) ───────────────────────────────────
if ($WebhookData) {
    Write-Output ""
    Write-Output "[INFO] Triggered by webhook/alert"
    try {
        $body = if ($WebhookData -is [string]) {
            $WebhookData | ConvertFrom-Json
        }
        elseif ($WebhookData.RequestBody) {
            $WebhookData.RequestBody | ConvertFrom-Json
        }
        else { $WebhookData }

        Write-Output "  Alert: $($body.data.essentials.alertRule)"
        Write-Output "  Severity: $($body.data.essentials.severity)"
        Write-Output "  Fired: $($body.data.essentials.firedDateTime)"
    }
    catch {
        Write-Warning "Could not parse webhook: $($_.Exception.Message)"
    }
}

# ── Authenticate ─────────────────────────────────────────────────────────
Write-Output ""
Write-Output "[STEP] Authenticating..."
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Write-Output "[OK] Authenticated"

# ── Build config ─────────────────────────────────────────────────────────
$config = @{
    ProjectName          = $ProjectName
    Environment          = $Environment
    PrimaryRegion        = $PrimaryRegion
    SecondaryRegion      = $SecondaryRegion
    PrimaryRegionShort   = "scus"
    SecondaryRegionShort = "ncus"
    PrimaryResourceGroup   = "rg-$ProjectName-$Environment-scus"
    SecondaryResourceGroup = "rg-$ProjectName-$Environment-ncus"
    SqlMiPrimaryName       = "sqlmi-$ProjectName-$Environment-scus"
    SqlMiSecondaryName     = "sqlmi-$ProjectName-$Environment-ncus"
    SqlMiFailoverGroupName = "fog-$ProjectName-$Environment"
    RedisPrimaryName       = "redis-$ProjectName-$Environment-scus"
    RedisSecondaryName     = "redis-$ProjectName-$Environment-ncus"
    FrontDoorProfileName   = "fd-$ProjectName-$Environment"
    FrontDoorResourceGroup = "rg-$ProjectName-$Environment-scus"
    KeyVaultName           = "kv-$ProjectName-$Environment"
    KeyVaultResourceGroup  = "rg-$ProjectName-$Environment-scus"
    FuncAppPrimaryName     = "func-$ProjectName-$Environment-scus"
    FuncAppSecondaryName   = "func-$ProjectName-$Environment-ncus"
}

# ── Determine target ────────────────────────────────────────────────────
$targetRG = if ($Action -eq "failover") { $config.SecondaryResourceGroup } else { $config.PrimaryResourceGroup }
$targetLocation = if ($Action -eq "failover") { $config.SecondaryRegion } else { $config.PrimaryRegion }
$newActiveRegion = $targetLocation

Write-Output ""
Write-Output "[INFO] Target: $targetLocation ($Action)"

# ── SQL MI FOG Switch ───────────────────────────────────────────────────
Write-Output ""
Write-Output "[STEP] SQL MI Failover Group switch..."
$sqlStart = Get-Date

try {
    if ($FailoverType -eq "Forced") {
        Switch-AzSqlDatabaseInstanceFailoverGroup `
            -ResourceGroupName $targetRG `
            -Location $targetLocation `
            -Name $config.SqlMiFailoverGroupName `
            -AllowDataLoss `
            -ErrorAction Stop | Out-Null
    }
    else {
        Switch-AzSqlDatabaseInstanceFailoverGroup `
            -ResourceGroupName $targetRG `
            -Location $targetLocation `
            -Name $config.SqlMiFailoverGroupName `
            -ErrorAction Stop | Out-Null
    }
    $sqlDuration = ((Get-Date) - $sqlStart).TotalSeconds
    Write-Output "[OK] SQL MI FOG switched in ${sqlDuration}s"
}
catch {
    Write-Error "SQL MI FOG switch failed: $($_.Exception.Message)"
    throw
}

# ── Wait ────────────────────────────────────────────────────────────────
Write-Output "[STEP] Post-switch stabilization..."
Start-Sleep -Seconds 15

# ── Front Door Origins ──────────────────────────────────────────────────
Write-Output "[STEP] Front Door origin priority swap..."
try {
    $originGroups = Get-AzFrontDoorCdnOriginGroup `
        -ResourceGroupName $config.FrontDoorResourceGroup `
        -ProfileName $config.FrontDoorProfileName

    foreach ($og in $originGroups) {
        $origins = Get-AzFrontDoorCdnOrigin `
            -ResourceGroupName $config.FrontDoorResourceGroup `
            -ProfileName $config.FrontDoorProfileName `
            -OriginGroupName $og.Name

        foreach ($origin in $origins) {
            $isTarget = $origin.Name -match $(
                if ($Action -eq "failover") { 'secondary' } else { 'primary' }
            )
            $newPriority = if ($isTarget) { 1 } else { 2 }

            Update-AzFrontDoorCdnOrigin `
                -ResourceGroupName $config.FrontDoorResourceGroup `
                -ProfileName $config.FrontDoorProfileName `
                -OriginGroupName $og.Name `
                -OriginName $origin.Name `
                -Priority $newPriority | Out-Null
        }
    }
    Write-Output "[OK] Front Door origins updated"
}
catch {
    Write-Warning "Front Door update failed (non-fatal): $($_.Exception.Message)"
}

# ── Key Vault ───────────────────────────────────────────────────────────
Write-Output "[STEP] Update Key Vault active-region..."
try {
    $secretValue = ConvertTo-SecureString -String $newActiveRegion -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $config.KeyVaultName -Name "active-region" -SecretValue $secretValue | Out-Null
    Write-Output "[OK] active-region = $newActiveRegion"
}
catch {
    Write-Warning "Key Vault update failed: $($_.Exception.Message)"
}

# ── Done ────────────────────────────────────────────────────────────────
$totalDuration = ((Get-Date) - $drillStart).TotalSeconds

Write-Output ""
Write-Output "============================================"
Write-Output "  Runbook Complete"
Write-Output "  Action: $Action"
Write-Output "  New Active Region: $newActiveRegion"
Write-Output "  Total Duration: ${totalDuration}s"
Write-Output "============================================"
