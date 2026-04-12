#Requires -Version 7.0
<#
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║   RAD Showcase — Environment Bootstrap Script                              ║
║                                                                            ║
║   PURPOSE:                                                                 ║
║     Automates the FULL setup of a RAD Showcase environment from scratch.   ║
║     Forks repos, configures files, provisions Azure infrastructure,        ║
║     sets GitHub secrets, triggers CI/CD pipelines, and verifies health.    ║
║                                                                            ║
║   WHAT IT DOES (11 phases):                                                ║
║     1. Prereqs      - Validates tools (az, gh, terraform, etc.) + login    ║
║     2. ForkClone    - Forks 6 repos to your org + clones locally           ║
║     3. Configure    - Updates env.hcl, module sources, APIM config         ║
║     4. TFState      - Creates TF state backend (RG + storage + container)  ║
║     5. OIDC/Runners - Creates identity (OIDC SP or self-hosted runner MI)  ║
║     6. GitHubSetup  - Creates environments + sets ALL GitHub secrets       ║
║     7. Infra        - Runs terragrunt apply (2-6 hrs for SQL MI)           ║
║     8. PostInfra    - Reads outputs, sets SQL_MI_FQDN secret               ║
║     9. Deploy       - Enables Actions, triggers pipelines in order         ║
║    10. PostDeploy   - Seeds KV secrets, RBAC upgrades, DNS zones           ║
║    11. Verify       - Tests Front Door routes + backend health             ║
║                                                                            ║
║   RUNNER MODES:                                                            ║
║     GitHubHosted  - Uses public GitHub runners + OIDC for auth (default)   ║
║     SelfHosted    - Provisions Azure VMSS runners + Managed Identity       ║
║                                                                            ║
║   PREREQUISITES:                                                           ║
║     - PowerShell 7+ (pwsh)                                                 ║
║     - Azure CLI (az) — logged in: az login                                 ║
║     - GitHub CLI (gh) — logged in: gh auth login                           ║
║     - Terraform >= 1.5                                                     ║
║     - Terragrunt >= 1.0                                                    ║
║     - Docker (optional — only for local container builds)                   ║
║     - Git                                                                  ║
║                                                                            ║
║   HOW TO RUN:                                                              ║
║                                                                            ║
║     # Full setup (interactive prompts for all values):                     ║
║     .\bootstrap-environment.ps1                                            ║
║                                                                            ║
║     # Full setup with self-hosted runners:                                 ║
║     .\bootstrap-environment.ps1 -RunnerMode SelfHosted                     ║
║                                                                            ║
║     # Resume from a specific phase (after SQL MI wait, etc.):              ║
║     .\bootstrap-environment.ps1 -Phase PostInfra                           ║
║                                                                            ║
║     # Preview what would happen (no changes made):                         ║
║     .\bootstrap-environment.ps1 -DryRun                                    ║
║                                                                            ║
║     # Run a specific phase with self-hosted runners:                       ║
║     .\bootstrap-environment.ps1 -Phase RunnerInfra -RunnerMode SelfHosted  ║
║                                                                            ║
║   PARAMETERS YOU WILL BE PROMPTED FOR:                                     ║
║     - GitHub org name (your org to fork into)                              ║
║     - Environment (DEV01, STG01, or PRD01)                                 ║
║     - Azure Subscription ID and Tenant ID                                  ║
║     - Primary/Secondary regions and short codes                            ║
║     - Entra admin group Object ID (for SQL MI)                             ║
║     - TF state storage account name                                        ║
║     - DR failover password (entered securely)                              ║
║     - Zone redundancy per region (primary/secondary independently)         ║
║     - Runner VM size and subnet CIDR (SelfHosted mode only)                ║
║                                                                            ║
║   SAFE TO RE-RUN: All phases are idempotent — they check if work is        ║
║   already done before acting. You can safely re-run any phase.             ║
║                                                                            ║
║   LOGGING: Creates a timestamped log file in the current directory.        ║
║                                                                            ║
║   REPO: radshow-def (scripts/bootstrap-environment.ps1)                    ║
║   DOCS: See HANDOVER.md for full architecture and design decisions.        ║
║                                                                            ║
╚══════════════════════════════════════════════════════════════════════════════╝
#>

<#
.SYNOPSIS
    RAD Showcase Bootstrap Script — Automates full environment setup from fork to verification.

.DESCRIPTION
    This script automates Steps 0-8 from HANDOVER.md for the RAD Showcase solution.
    Supports two runner modes: GitHubHosted (OIDC) and SelfHosted (Managed Identity on VMSS).

.PARAMETER Phase
    Which phase to execute. Use 'All' to run everything sequentially.

.PARAMETER RunnerMode
    GitHubHosted (default) - Uses public GitHub runners with OIDC federated credentials.
    SelfHosted - Provisions Azure VMSS runners with Managed Identity (no OIDC needed).

.PARAMETER DryRun
    Print what would be done without executing any changes.

.EXAMPLE
    .\bootstrap-environment.ps1
.EXAMPLE
    .\bootstrap-environment.ps1 -RunnerMode SelfHosted
.EXAMPLE
    .\bootstrap-environment.ps1 -Phase PostInfra
.EXAMPLE
    .\bootstrap-environment.ps1 -DryRun
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('All', 'Prereqs', 'ForkClone', 'Configure', 'TFState', 'OIDC', 'RunnerInfra', 'GitHubSetup', 'Infra', 'PostInfra', 'Deploy', 'PostDeploy', 'Verify')]
    [string]$Phase = 'All',

    [ValidateSet('GitHubHosted', 'SelfHosted')]
    [string]$RunnerMode = 'GitHubHosted',

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
#region Constants
# ============================================================================

$REPOS = @('radshow-def', 'radshow-lic', 'radshow-api', 'radshow-spa', 'radshow-db', 'radshow-apim')
$APP_REPOS = @('radshow-lic', 'radshow-api', 'radshow-spa', 'radshow-db', 'radshow-apim')
$PIPELINE_REPOS = @('radshow-db', 'radshow-api', 'radshow-apim', 'radshow-spa')
$OIDC_ISSUER = 'https://token.actions.githubusercontent.com'
$OIDC_AUDIENCE = 'api://AzureADTokenExchange'

$PHASE_ORDER_GITHUB_HOSTED = @(
    'Prereqs', 'ForkClone', 'Configure', 'TFState', 'OIDC',
    'GitHubSetup', 'Infra', 'PostInfra', 'Deploy', 'PostDeploy', 'Verify'
)

$PHASE_ORDER_SELF_HOSTED = @(
    'Prereqs', 'ForkClone', 'Configure', 'TFState', 'RunnerInfra',
    'GitHubSetup', 'Infra', 'PostInfra', 'Deploy', 'PostDeploy', 'Verify'
)

#endregion

# ============================================================================
#region Helper Functions
# ============================================================================

function Write-Phase {
    param([string]$Name, [string]$Description)
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "  PHASE: $Name" -ForegroundColor Cyan
    Write-Host "  $Description" -ForegroundColor DarkCyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    Write-Host "  >> $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  [SKIP] $Message" -ForegroundColor DarkGray
}

function Write-Err {
    param([string]$Message)
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor White
}

function Read-Parameter {
    param(
        [string]$Prompt,
        [string]$Default = '',
        [switch]$Required,
        [switch]$IsSecure
    )
    $displayPrompt = if ($Default) { "$Prompt [$Default]" } else { "$Prompt" }

    while ($true) {
        if ($IsSecure) {
            $value = Read-Host -Prompt $displayPrompt -AsSecureString
            $plainText = [System.Net.NetworkCredential]::new('', $value).Password
            if (-not $plainText -and $Default) { return $Default }
            if (-not $plainText -and $Required) {
                Write-Err "This parameter is required."
                continue
            }
            return $plainText
        }
        else {
            $value = Read-Host -Prompt $displayPrompt
            if (-not $value -and $Default) { return $Default }
            if (-not $value -and $Required) {
                Write-Err "This parameter is required."
                continue
            }
            return $value
        }
    }
}

function Invoke-CommandSafe {
    param(
        [string]$Description,
        [scriptblock]$Command,
        [switch]$AllowFailure
    )
    Write-Step $Description
    if ($DryRun) {
        Write-Info "[DRY RUN] Would execute: $($Command.ToString().Trim())"
        return $null
    }
    try {
        $result = & $Command 2>&1
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            if ($AllowFailure) {
                Write-Err "Command returned exit code $LASTEXITCODE (non-fatal)"
                return $null
            }
            throw "Command failed with exit code $LASTEXITCODE`n$($result | Out-String)"
        }
        return $result
    }
    catch {
        if ($AllowFailure) {
            Write-Err "$($_.Exception.Message) (non-fatal)"
            return $null
        }
        throw
    }
}

function Test-AzResourceExists {
    param([string]$ResourceId)
    $result = az resource show --ids $ResourceId 2>&1
    return $LASTEXITCODE -eq 0
}

#endregion

# ============================================================================
#region Parameter Collection
# ============================================================================

function Get-BootstrapConfig {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Magenta
    Write-Host "  RAD Showcase — Environment Bootstrap" -ForegroundColor Magenta
    Write-Host "  Answer the following prompts to configure your environment." -ForegroundColor DarkMagenta
    Write-Host "  Press Enter to accept defaults shown in [brackets]." -ForegroundColor DarkMagenta
    Write-Host ("=" * 80) -ForegroundColor Magenta
    Write-Host ""

    # --- Source & Target Org ---
    Write-Host "--- GitHub Configuration ---" -ForegroundColor Cyan
    Write-Host "  Enter org/user name only (e.g. 'DeepMalh44'), NOT a full URL." -ForegroundColor DarkGray
    $sourceOrg = Read-Parameter -Prompt "Source GitHub org (fork from)" -Default "DeepMalh44"
    $gitHubOrg = Read-Parameter -Prompt "Your GitHub org (fork to)" -Required

    # Sanitize: strip URL prefixes and trailing slashes
    $sourceOrg = $sourceOrg -replace '^https?://github\.com/', '' -replace '/$', ''
    $gitHubOrg = $gitHubOrg -replace '^https?://github\.com/', '' -replace '/$', ''

    $reposBasePath = Read-Parameter -Prompt "Local path to clone repos into" -Default "$HOME\repos\radshow" -Required

    # --- Environment ---
    Write-Host ""
    Write-Host "--- Environment ---" -ForegroundColor Cyan
    $environment = Read-Parameter -Prompt "Environment name (DEV01, STG01, PRD01)" -Required
    if ($environment -notin @('DEV01', 'STG01', 'PRD01')) {
        Write-Err "Invalid environment: $environment. Must be DEV01, STG01, or PRD01."
        exit 1
    }

    # --- Azure ---
    Write-Host ""
    Write-Host "--- Azure Subscription ---" -ForegroundColor Cyan
    $subscriptionId = Read-Parameter -Prompt "Azure Subscription ID" -Required
    $tenantId = Read-Parameter -Prompt "Azure Tenant ID" -Required

    # --- Regions ---
    Write-Host ""
    Write-Host "--- Regions ---" -ForegroundColor Cyan
    Write-Host "  Common pairs: swedencentral/germanywestcentral (swc/gwc)" -ForegroundColor DarkGray
    Write-Host "                centralindia/southindia (cin/sin)" -ForegroundColor DarkGray
    Write-Host "                southcentralus/northcentralus (scus/ncus)" -ForegroundColor DarkGray
    $primaryLocation = Read-Parameter -Prompt "Primary region (e.g. swedencentral)" -Required
    $primaryShort = Read-Parameter -Prompt "Primary region short code (e.g. swc)" -Required
    $secondaryLocation = Read-Parameter -Prompt "Secondary region (e.g. germanywestcentral)" -Required
    $secondaryShort = Read-Parameter -Prompt "Secondary region short code (e.g. gwc)" -Required

    # --- SQL MI ---
    Write-Host ""
    Write-Host "--- SQL Managed Instance ---" -ForegroundColor Cyan
    $entraAdminGroupOid = Read-Parameter -Prompt "Entra admin security group Object ID (for SQL MI)" -Required
    $sqlDatabaseName = Read-Parameter -Prompt "SQL database name" -Default "radshow"

    # --- TF State ---
    Write-Host ""
    Write-Host "--- Terraform State Backend ---" -ForegroundColor Cyan
    $tfStateStorageAccount = Read-Parameter -Prompt "TF state storage account name (globally unique)" -Default "stradshwtfstate"
    $tfStateResourceGroup = Read-Parameter -Prompt "TF state resource group name" -Default "rg-radshow-tfstate"
    $tfStateContainer = Read-Parameter -Prompt "TF state blob container name" -Default "tfstate"

    # --- DR Password ---
    Write-Host ""
    Write-Host "--- DR Automation ---" -ForegroundColor Cyan
    $drPassword = Read-Parameter -Prompt "DR failover password (for Key Vault)" -Required -IsSecure

    # --- Zone Redundancy (per region) ---
    Write-Host ""
    Write-Host "--- Availability Zone Redundancy ---" -ForegroundColor Cyan
    Write-Host "  Not all Azure regions support availability zones." -ForegroundColor DarkGray
    Write-Host "  You can enable zone redundancy independently for each region." -ForegroundColor DarkGray
    Write-Host "  This affects: Function App, App Service, Container Apps, SQL MI, Redis, ACR, APIM." -ForegroundColor DarkGray
    Write-Host ""
    $zoneRedundantPrimary = Read-Parameter -Prompt "Enable zone redundancy for PRIMARY region ($primaryLocation)?  (Y/n)" -Default "n"
    $enableZonePrimary = ($zoneRedundantPrimary -eq 'Y' -or $zoneRedundantPrimary -eq 'y')
    $zoneRedundantSecondary = Read-Parameter -Prompt "Enable zone redundancy for SECONDARY region ($secondaryLocation)? (Y/n)" -Default "n"
    $enableZoneSecondary = ($zoneRedundantSecondary -eq 'Y' -or $zoneRedundantSecondary -eq 'y')
    if ($enableZonePrimary) {
        Write-Info "  Primary ($primaryLocation): MULTI-ZONE (zones 1, 2, 3)"
    } else {
        Write-Info "  Primary ($primaryLocation): SINGLE-ZONE"
    }
    if ($enableZoneSecondary) {
        Write-Info "  Secondary ($secondaryLocation): MULTI-ZONE (zones 1, 2, 3)"
    } else {
        Write-Info "  Secondary ($secondaryLocation): SINGLE-ZONE"
    }

    # --- Self-Hosted Runner Config (only if RunnerMode is SelfHosted) ---
    $runnerVmSize = ''
    $runnerSubnetCidr = ''
    $runnerCount = 2
    if ($RunnerMode -eq 'SelfHosted') {
        Write-Host ""
        Write-Host "--- Self-Hosted Runner Configuration ---" -ForegroundColor Cyan
        Write-Host "  Runners will be provisioned as Azure VMSS with Managed Identity." -ForegroundColor DarkGray
        Write-Host "  This replaces OIDC — no App Registration or federated credentials needed." -ForegroundColor DarkGray
        $runnerVmSize = Read-Parameter -Prompt "Runner VM size" -Default "Standard_D4s_v5"
        $runnerSubnetCidr = Read-Parameter -Prompt "Runner subnet CIDR (needs /26 min)" -Default "10.0.9.0/26"
        $runnerCount = [int](Read-Parameter -Prompt "Number of runner instances per region" -Default "2")
    }

    # Derive all resource names from naming convention
    $envLower = $environment.ToLower()

    $config = @{
        # Input parameters
        SourceOrg              = $sourceOrg
        GitHubOrg              = $gitHubOrg
        ReposBasePath          = $reposBasePath
        Environment            = $environment
        EnvironmentLower       = $envLower
        SubscriptionId         = $subscriptionId
        TenantId               = $tenantId
        PrimaryLocation        = $primaryLocation
        PrimaryShort           = $primaryShort.ToLower()
        SecondaryLocation      = $secondaryLocation
        SecondaryShort         = $secondaryShort.ToLower()
        EntraAdminGroupOid     = $entraAdminGroupOid
        SqlDatabaseName        = $sqlDatabaseName
        TfStateStorageAccount  = $tfStateStorageAccount
        TfStateResourceGroup   = $tfStateResourceGroup
        TfStateContainer       = $tfStateContainer
        DRPassword             = $drPassword

        # Derived — Resource Groups
        ResourceGroupPrimary   = "rg-radshow-$envLower-$($primaryShort.ToLower())"
        ResourceGroupSecondary = "rg-radshow-$envLower-$($secondaryShort.ToLower())"

        # Derived — Compute
        FunctionAppPrimary     = "func-radshow-$envLower-$($primaryShort.ToLower())"
        FunctionAppSecondary   = "func-radshow-$envLower-$($secondaryShort.ToLower())"
        AppServicePrimary      = "app-radshow-$envLower-$($primaryShort.ToLower())"
        AppServiceSecondary    = "app-radshow-$envLower-$($secondaryShort.ToLower())"
        ContainerAppPrimary    = "ca-products-radshow-$envLower-$($primaryShort.ToLower())"
        ContainerAppSecondary  = "ca-products-radshow-$envLower-$($secondaryShort.ToLower())"

        # Derived — Data & Caching
        StorageAccountPrimary  = "stradshow$envLower$($primaryShort.ToLower())"
        StorageAccountSecondary = "stradshow$envLower$($secondaryShort.ToLower())"
        AcrName                = "acrradshow$envLower"
        SqlMiFogName           = "fog-radshow-$envLower"
        RedisPrimary           = "redis-radshow-$envLower-$($primaryShort.ToLower())"
        RedisSecondary         = "redis-radshow-$envLower-$($secondaryShort.ToLower())"

        # Derived — Networking & Security
        KeyVaultPrimary        = "kv-radshow-$envLower-$($primaryShort.ToLower())"
        KeyVaultSecondary      = "kv-radshow-$envLower-$($secondaryShort.ToLower())"
        ApimName               = "apim-radshow-$envLower-$($primaryShort.ToLower())"
        FrontDoorProfile       = "afd-radshow-$envLower"
        FrontDoorEndpoint      = "ep-spa"

        # Derived — OIDC
        SpDisplayName          = "sp-radshow-cicd-$envLower"

        # Zone redundancy (per region)
        ZoneRedundantPrimary   = $enableZonePrimary
        ZoneRedundantSecondary = $enableZoneSecondary

        # Runner mode
        RunnerMode             = $RunnerMode

        # Self-hosted runner config (empty for GitHubHosted)
        RunnerVmSize           = $runnerVmSize
        RunnerSubnetCidr       = $runnerSubnetCidr
        RunnerCount            = $runnerCount
        RunnerVmssNamePrimary  = "vmss-runner-radshow-$envLower-$($primaryShort.ToLower())"
        RunnerVmssNameSecondary = "vmss-runner-radshow-$envLower-$($secondaryShort.ToLower())"
        RunnerSubnetPrimary    = "snet-runners-$($primaryShort.ToLower())"
        RunnerSubnetSecondary  = "snet-runners-$($secondaryShort.ToLower())"
        RunnerNatGwPrimary     = "natgw-runner-radshow-$envLower-$($primaryShort.ToLower())"
        RunnerNatGwSecondary   = "natgw-runner-radshow-$envLower-$($secondaryShort.ToLower())"
        RunnerNsgPrimary       = "nsg-runner-radshow-$envLower-$($primaryShort.ToLower())"
        RunnerNsgSecondary     = "nsg-runner-radshow-$envLower-$($secondaryShort.ToLower())"
    }

    # Display summary
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "  Configuration Summary" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    Write-Host "  GitHub: $($config.SourceOrg) -> $($config.GitHubOrg)" -ForegroundColor White
    Write-Host "  Environment: $($config.Environment)" -ForegroundColor White
    Write-Host "  Subscription: $($config.SubscriptionId)" -ForegroundColor White
    Write-Host "  Tenant: $($config.TenantId)" -ForegroundColor White
    Write-Host "  Primary: $($config.PrimaryLocation) ($($config.PrimaryShort)) — $(if ($config.ZoneRedundantPrimary) { 'MULTI-ZONE' } else { 'SINGLE-ZONE' })" -ForegroundColor White
    Write-Host "  Secondary: $($config.SecondaryLocation) ($($config.SecondaryShort)) — $(if ($config.ZoneRedundantSecondary) { 'MULTI-ZONE' } else { 'SINGLE-ZONE' })" -ForegroundColor White
    Write-Host "  Repos path: $($config.ReposBasePath)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Resource groups: $($config.ResourceGroupPrimary), $($config.ResourceGroupSecondary)" -ForegroundColor DarkGray
    Write-Host "  Function apps:   $($config.FunctionAppPrimary), $($config.FunctionAppSecondary)" -ForegroundColor DarkGray
    Write-Host "  Storage:          $($config.StorageAccountPrimary), $($config.StorageAccountSecondary)" -ForegroundColor DarkGray
    Write-Host "  ACR:              $($config.AcrName)" -ForegroundColor DarkGray
    Write-Host "  APIM:             $($config.ApimName)" -ForegroundColor DarkGray
    Write-Host "  Front Door:       $($config.FrontDoorProfile)" -ForegroundColor DarkGray
    Write-Host "  Key Vaults:       $($config.KeyVaultPrimary), $($config.KeyVaultSecondary)" -ForegroundColor DarkGray
    Write-Host "  Runner mode:      $($config.RunnerMode)" -ForegroundColor DarkGray
    if ($config.RunnerMode -eq 'SelfHosted') {
        Write-Host "  Runner VMSS:      $($config.RunnerVmssNamePrimary), $($config.RunnerVmssNameSecondary)" -ForegroundColor DarkGray
        Write-Host "  Runner VM size:   $($config.RunnerVmSize)" -ForegroundColor DarkGray
        Write-Host "  Runner subnet:    $($config.RunnerSubnetCidr) ($($config.RunnerCount) instances/region)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Service Principal: $($config.SpDisplayName)" -ForegroundColor DarkGray
    }
    Write-Host ""

    $confirm = Read-Host "  Proceed with this configuration? (Y/n)"
    if ($confirm -and $confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Aborted by user." -ForegroundColor Red
        exit 0
    }

    return $config
}

#endregion

# ============================================================================
#region Phase: Prerequisites
# ============================================================================

function Invoke-PrereqsPhase {
    param([hashtable]$Config)
    Write-Phase "Prerequisites" "Validating required tools and authentication"

    $requiredTools = @(
        @{ Name = 'az';         Check = { az version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } }
        @{ Name = 'gh';         Check = { gh --version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } }
        @{ Name = 'terraform';  Check = { terraform version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } }
        @{ Name = 'terragrunt'; Check = { terragrunt --version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } }
        @{ Name = 'git';        Check = { git --version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 } }
    )

    $optionalTools = @(
        @{ Name = 'docker'; Check = { docker version 2>&1 | Out-Null; $LASTEXITCODE -eq 0 }; Reason = 'Only needed for local container builds — ACR Tasks handles cloud builds' }
    )

    $allGood = $true
    foreach ($tool in $requiredTools) {
        Write-Step "Checking $($tool.Name)..."
        if (& $tool.Check) {
            Write-Success "$($tool.Name) is installed"
        }
        else {
            Write-Err "$($tool.Name) is not installed or not in PATH"
            $allGood = $false
        }
    }

    foreach ($tool in $optionalTools) {
        Write-Step "Checking $($tool.Name) (optional)..."
        if (& $tool.Check) {
            Write-Success "$($tool.Name) is installed"
        }
        else {
            Write-Host "  [WARN] $($tool.Name) is not installed — $($tool.Reason)" -ForegroundColor DarkYellow
        }
    }

    # Check Azure login
    Write-Step "Checking Azure CLI login..."
    $azAccount = az account show --query '{name:name, id:id}' -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $acct = $azAccount | ConvertFrom-Json
        Write-Success "Logged into Azure: $($acct.name) ($($acct.id))"
    }
    else {
        Write-Err "Not logged into Azure CLI. Run 'az login' first."
        $allGood = $false
    }

    # Set the correct subscription
    Write-Step "Setting Azure subscription to $($Config.SubscriptionId)..."
    if (-not $DryRun) {
        az account set --subscription $Config.SubscriptionId 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Failed to set subscription $($Config.SubscriptionId). Check access."
            $allGood = $false
        }
        else {
            Write-Success "Subscription set"
        }
    }

    # Check GitHub CLI login
    Write-Step "Checking GitHub CLI login..."
    $ghStatus = gh auth status 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Logged into GitHub CLI"
    }
    else {
        Write-Err "Not logged into GitHub CLI. Run 'gh auth login' first."
        $allGood = $false
    }

    if (-not $allGood) {
        Write-Err "Prerequisites check failed. Fix issues above and re-run."
        exit 1
    }

    Write-Success "All prerequisites passed"
}

#endregion

# ============================================================================
#region Phase: Fork & Clone
# ============================================================================

function Invoke-ForkClonePhase {
    param([hashtable]$Config)
    Write-Phase "Fork & Clone" "Forking repos from $($Config.SourceOrg) to $($Config.GitHubOrg) and cloning locally"

    # Ensure base path exists
    if (-not (Test-Path $Config.ReposBasePath)) {
        Write-Step "Creating repos directory: $($Config.ReposBasePath)"
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $Config.ReposBasePath -Force | Out-Null
        }
        Write-Success "Created $($Config.ReposBasePath)"
    }

    # Work from the repos base path so gh clone lands in the right place
    Push-Location $Config.ReposBasePath

    try {
        foreach ($repo in $REPOS) {
            $localPath = Join-Path $Config.ReposBasePath $repo
            $sourceRepo = "$($Config.SourceOrg)/$repo"
            $targetRepo = "$($Config.GitHubOrg)/$repo"

            if (Test-Path $localPath) {
                Write-Skip "$repo already exists at $localPath"
                continue
            }

            # Check if fork already exists in target org
            Write-Step "Checking if $targetRepo exists on GitHub..."
            $repoExists = $false
            if (-not $DryRun) {
                gh repo view $targetRepo 2>&1 | Out-Null
                $repoExists = ($LASTEXITCODE -eq 0)
            }

            if ($repoExists) {
                Write-Step "Fork exists, cloning $targetRepo..."
                Invoke-CommandSafe -Description "Cloning $targetRepo" -Command {
                    gh repo clone $targetRepo $localPath
                }
            }
            else {
                Write-Step "Forking $sourceRepo to $($Config.GitHubOrg) and cloning..."

                # Detect if target is a GitHub org or personal account
                $isOrg = $false
                gh api "orgs/$($Config.GitHubOrg)" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $isOrg = $true }

                if ($isOrg) {
                    Write-Info "  Target is a GitHub organization — using --org flag"
                    $forkOutput = gh repo fork $sourceRepo --org $Config.GitHubOrg --clone=true 2>&1
                }
                else {
                    Write-Info "  Target is a personal account — forking to authenticated user"
                    $forkOutput = gh repo fork $sourceRepo --clone=true --default-branch-only 2>&1
                }
                $forkExitCode = $LASTEXITCODE

                if ($forkExitCode -ne 0 -and -not (Test-Path $localPath)) {
                    Write-Err "Fork failed for $repo (exit code $forkExitCode):"
                    Write-Host "    $forkOutput" -ForegroundColor Red
                    Write-Info "  Fork manually: https://github.com/$sourceRepo/fork"
                    Write-Info "  Then clone:    gh repo clone $targetRepo $localPath"
                    continue
                }
            }

            if (-not $DryRun -and (Test-Path $localPath)) {
                Write-Success "$repo forked and cloned to $localPath"
            }
        }
    }
    finally {
        Pop-Location
    }
}

#endregion

# ============================================================================
#region Phase: Configure Files
# ============================================================================

function Invoke-ConfigurePhase {
    param([hashtable]$Config)
    Write-Phase "Configure" "Updating configuration files across all repos"

    $licPath = Join-Path $Config.ReposBasePath "radshow-lic"
    $apimPath = Join-Path $Config.ReposBasePath "radshow-apim"

    if (-not (Test-Path $licPath)) {
        Write-Err "radshow-lic not found at $licPath. Run ForkClone phase first."
        exit 1
    }

    # --- Update env.hcl ---
    $envHclPath = Join-Path $licPath $Config.Environment "env.hcl"
    if (Test-Path $envHclPath) {
        Write-Step "Updating $($Config.Environment)/env.hcl..."
        if (-not $DryRun) {
            $content = Get-Content $envHclPath -Raw
            # Replace subscription_id value
            $content = $content -replace '(subscription_id\s*=\s*")[^"]*(")', "`${1}$($Config.SubscriptionId)`${2}"
            # Replace tenant_id value
            $content = $content -replace '(tenant_id\s*=\s*")[^"]*(")', "`${1}$($Config.TenantId)`${2}"
            # Replace primary location
            $content = $content -replace '(primary_location\s*=\s*")[^"]*(")', "`${1}$($Config.PrimaryLocation)`${2}"
            # Replace secondary location
            $content = $content -replace '(secondary_location\s*=\s*")[^"]*(")', "`${1}$($Config.SecondaryLocation)`${2}"
            # Replace short codes
            $content = $content -replace '(primary_short\s*=\s*")[^"]*(")', "`${1}$($Config.PrimaryShort)`${2}"
            $content = $content -replace '(secondary_short\s*=\s*")[^"]*(")', "`${1}$($Config.SecondaryShort)`${2}"
            Set-Content -Path $envHclPath -Value $content -NoNewline
        }
        Write-Success "Updated env.hcl"
    }
    else {
        Write-Err "env.hcl not found at $envHclPath — check environment name"
    }

    # --- Update SQL MI Entra admin OID ---
    $sqlMiHclPath = Join-Path $licPath $Config.Environment "sql-mi" "terragrunt.hcl"
    if (Test-Path $sqlMiHclPath) {
        Write-Step "Updating SQL MI Entra admin Object ID..."
        if (-not $DryRun) {
            $content = Get-Content $sqlMiHclPath -Raw
            $content = $content -replace '(entra_admin_object_id\s*=\s*")[^"]*(")', "`${1}$($Config.EntraAdminGroupOid)`${2}"
            Set-Content -Path $sqlMiHclPath -Value $content -NoNewline
        }
        Write-Success "Updated SQL MI admin OID"
    }

    # --- Set zone redundancy flags on per-region Terragrunt configs ---
    if (-not $DryRun) {
        Write-Step "Setting zone redundancy flags in Terragrunt configs..."

        # Map of module folder suffix -> zone variable name -> zone value format
        # 'bool' modules use zone_redundant = true/false
        # 'list' modules use zones = ["1","2","3"] or []
        $zoneModules = @(
            @{ Folder = 'function-app';         Var = 'zone_redundant';          Type = 'bool' }
            @{ Folder = 'function-app-secondary'; Var = 'zone_redundant';        Type = 'bool' }
            @{ Folder = 'app-service';           Var = 'zone_redundant';          Type = 'bool' }
            @{ Folder = 'app-service-secondary'; Var = 'zone_redundant';          Type = 'bool' }
            @{ Folder = 'container-apps';        Var = 'zone_redundancy_enabled'; Type = 'bool' }
            @{ Folder = 'container-apps-secondary'; Var = 'zone_redundancy_enabled'; Type = 'bool' }
            @{ Folder = 'sql-mi';                Var = 'zone_redundant';          Type = 'bool' }
            @{ Folder = 'sql-mi-secondary';      Var = 'zone_redundant';          Type = 'bool' }
            @{ Folder = 'redis';                 Var = 'zones';                   Type = 'list' }
            @{ Folder = 'redis-secondary';        Var = 'zones';                  Type = 'list' }
            @{ Folder = 'container-registry';     Var = 'zone_redundancy_enabled'; Type = 'bool' }
        )

        foreach ($mod in $zoneModules) {
            $isPrimary = $mod.Folder -notmatch '-secondary$'
            $zoneEnabled = if ($isPrimary) { $Config.ZoneRedundantPrimary } else { $Config.ZoneRedundantSecondary }

            # Container Registry is single (primary) but zone setting applies to primary region
            if ($mod.Folder -eq 'container-registry') { $zoneEnabled = $Config.ZoneRedundantPrimary }

            $hclPath = Join-Path $licPath $Config.Environment $mod.Folder "terragrunt.hcl"
            if (-not (Test-Path $hclPath)) {
                # Try _envcommon path
                $hclPath = Join-Path $licPath "_envcommon" "$($mod.Folder).hcl"
            }
            if (Test-Path $hclPath) {
                $content = Get-Content $hclPath -Raw
                $varName = $mod.Var

                if ($mod.Type -eq 'bool') {
                    $newVal = if ($zoneEnabled) { 'true' } else { 'false' }
                    if ($content -match "($varName\s*=\s*)(true|false)") {
                        $content = $content -replace "($varName\s*=\s*)(true|false)", "`${1}$newVal"
                        Set-Content -Path $hclPath -Value $content -NoNewline
                        Write-Info "  $($mod.Folder): $varName = $newVal"
                    }
                    else {
                        Write-Info "  $($mod.Folder): $varName not found in config (will use module default)"
                    }
                }
                elseif ($mod.Type -eq 'list') {
                    $newVal = if ($zoneEnabled) { '["1", "2", "3"]' } else { '[]' }
                    if ($content -match "($varName\s*=\s*)(\[[^\]]*\])") {
                        $content = $content -replace "($varName\s*=\s*)(\[[^\]]*\])", "`${1}$newVal"
                        Set-Content -Path $hclPath -Value $content -NoNewline
                        Write-Info "  $($mod.Folder): $varName = $newVal"
                    }
                    else {
                        Write-Info "  $($mod.Folder): $varName not found in config (will use module default)"
                    }
                }
            }
        }

        # APIM zones — primary is in main config, secondary in additional_locations
        $apimEnvCommon = Join-Path $licPath "_envcommon" "apim.hcl"
        $apimEnvHcl = Join-Path $licPath $Config.Environment "apim" "terragrunt.hcl"
        $apimHclPath = if (Test-Path $apimEnvHcl) { $apimEnvHcl } elseif (Test-Path $apimEnvCommon) { $apimEnvCommon } else { $null }
        if ($apimHclPath) {
            $content = Get-Content $apimHclPath -Raw
            $primaryZones = if ($Config.ZoneRedundantPrimary) { '["1", "2", "3"]' } else { '[]' }
            if ($content -match '(zones\s*=\s*)(\[[^\]]*\])') {
                # Replace first occurrence only (primary zones)
                $content = [regex]::Replace($content, '(zones\s*=\s*)(\[[^\]]*\])', "`${1}$primaryZones", [System.Text.RegularExpressions.RegexOptions]::None)
                Set-Content -Path $apimHclPath -Value $content -NoNewline
                Write-Info "  apim: zones = $primaryZones"
            }
        }

        Write-Success "Zone redundancy flags updated"
    }

    # --- Update module source URLs in _envcommon ---
    $envCommonPath = Join-Path $licPath "_envcommon"
    if (Test-Path $envCommonPath) {
        Write-Step "Updating module source URLs in _envcommon (replacing $($Config.SourceOrg) with $($Config.GitHubOrg))..."
        if (-not $DryRun) {
            $hclFiles = Get-ChildItem -Path $envCommonPath -Filter "*.hcl" -Recurse
            foreach ($file in $hclFiles) {
                $content = Get-Content $file.FullName -Raw
                if ($content -match $Config.SourceOrg) {
                    $content = $content -replace [regex]::Escape($Config.SourceOrg), $Config.GitHubOrg
                    Set-Content -Path $file.FullName -Value $content -NoNewline
                    Write-Info "  Updated: $($file.Name)"
                }
            }
        }
        Write-Success "Module source URLs updated"
    }

    # --- Update root terragrunt.hcl TF state storage name ---
    $rootHclPath = Join-Path $licPath "terragrunt.hcl"
    if (Test-Path $rootHclPath) {
        Write-Step "Updating Terraform state storage account in root terragrunt.hcl..."
        if (-not $DryRun) {
            $content = Get-Content $rootHclPath -Raw
            $content = $content -replace '(storage_account_name\s*=\s*")[^"]*(")', "`${1}$($Config.TfStateStorageAccount)`${2}"
            Set-Content -Path $rootHclPath -Value $content -NoNewline
        }
        Write-Success "TF state storage account updated"
    }

    # --- Update OIDC script org ---
    $oidcScriptPath = Join-Path $licPath "scripts" "setup-github-oidc.sh"
    if (Test-Path $oidcScriptPath) {
        Write-Step "Updating GITHUB_ORG in setup-github-oidc.sh..."
        if (-not $DryRun) {
            $content = Get-Content $oidcScriptPath -Raw
            $content = $content -replace '(GITHUB_ORG=")[^"]*(")', "`${1}$($Config.GitHubOrg)`${2}"
            Set-Content -Path $oidcScriptPath -Value $content -NoNewline
        }
        Write-Success "OIDC script org updated"
    }

    # --- Update APIM configuration files ---
    if (Test-Path $apimPath) {
        $envShortMap = @{ 'DEV01' = 'dev'; 'STG01' = 'stg'; 'PRD01' = 'prd' }
        $apimConfigName = "configuration.$($envShortMap[$Config.Environment]).yaml"
        $apimConfigPath = Join-Path $apimPath $apimConfigName
        if (Test-Path $apimConfigPath) {
            Write-Step "Updating tenant-id in $apimConfigName..."
            if (-not $DryRun) {
                $content = Get-Content $apimConfigPath -Raw
                $content = $content -replace '(tenant-id["\s:]+)[0-9a-f-]{36}', "`${1}$($Config.TenantId)"
                Set-Content -Path $apimConfigPath -Value $content -NoNewline
            }
            Write-Success "APIM config updated"
        }
    }

    # --- Commit configuration changes ---
    Write-Step "Committing configuration changes to local repos..."
    if (-not $DryRun) {
        foreach ($repo in $REPOS) {
            $repoPath = Join-Path $Config.ReposBasePath $repo
            if (Test-Path $repoPath) {
                Push-Location $repoPath
                $status = git status --porcelain 2>&1
                if ($status) {
                    git add -A 2>&1 | Out-Null
                    git commit -m "chore: configure for $($Config.Environment) environment ($($Config.GitHubOrg))" 2>&1 | Out-Null
                    Write-Info "  Committed changes in $repo"
                }
                Pop-Location
            }
        }
    }
    Write-Success "Configuration phase complete"
}

#endregion

# ============================================================================
#region Phase: TF State Backend
# ============================================================================

function Invoke-TFStatePhase {
    param([hashtable]$Config)
    Write-Phase "TF State Backend" "Creating resource group, storage account, and blob container for Terraform state"

    # Create resource group
    Invoke-CommandSafe -Description "Creating resource group $($Config.TfStateResourceGroup)..." -Command {
        az group create `
            --name $Config.TfStateResourceGroup `
            --location $Config.PrimaryLocation `
            --output none
    }
    Write-Success "Resource group ready"

    # Create storage account
    Invoke-CommandSafe -Description "Creating storage account $($Config.TfStateStorageAccount)..." -Command {
        az storage account create `
            --name $Config.TfStateStorageAccount `
            --resource-group $Config.TfStateResourceGroup `
            --location $Config.PrimaryLocation `
            --sku Standard_ZRS `
            --kind StorageV2 `
            --https-only true `
            --min-tls-version TLS1_2 `
            --allow-blob-public-access false `
            --output none
    }
    Write-Success "Storage account ready"

    # Create blob container
    Invoke-CommandSafe -Description "Creating blob container $($Config.TfStateContainer)..." -Command {
        az storage container create `
            --name $Config.TfStateContainer `
            --account-name $Config.TfStateStorageAccount `
            --auth-mode login `
            --output none
    }
    Write-Success "Blob container ready"
}

#endregion

# ============================================================================
#region Phase: OIDC (Entra App Registration + Service Principal)
# ============================================================================

function Invoke-OIDCPhase {
    param([hashtable]$Config)
    Write-Phase "OIDC Setup" "Creating Entra App Registration, Service Principal, federated credentials, and RBAC"

    $spName = $Config.SpDisplayName

    # --- Create App Registration ---
    Write-Step "Creating App Registration: $spName..."
    $appId = $null
    $spObjectId = $null

    if (-not $DryRun) {
        # Check if already exists
        $existing = az ad app list --display-name $spName --query "[0].appId" -o tsv 2>&1
        if ($existing -and $LASTEXITCODE -eq 0 -and $existing -ne '') {
            $appId = $existing.Trim()
            Write-Skip "App Registration already exists: $appId"
        }
        else {
            $appResult = az ad app create --display-name $spName --query "appId" -o tsv 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to create App Registration: $appResult" }
            $appId = $appResult.Trim()
            Write-Success "App Registration created: $appId"
        }

        # --- Create Service Principal ---
        Write-Step "Creating Service Principal..."
        $existingSp = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv 2>&1
        if ($existingSp -and $LASTEXITCODE -eq 0 -and $existingSp -ne '') {
            $spObjectId = $existingSp.Trim()
            Write-Skip "Service Principal already exists: $spObjectId"
        }
        else {
            $spResult = az ad sp create --id $appId --query "id" -o tsv 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to create Service Principal: $spResult" }
            $spObjectId = $spResult.Trim()
            # Wait for propagation
            Start-Sleep -Seconds 10
            Write-Success "Service Principal created: $spObjectId"
        }

        # Store the SP OID for later use (updating env.hcl cicd_sp_object_id)
        $Config['CicdSpObjectId'] = $spObjectId

        # --- Create Federated Credentials ---
        Write-Step "Creating federated credentials (5 repos)..."
        foreach ($repo in $APP_REPOS) {
            $credName = "gh-$repo-$($Config.EnvironmentLower)"
            $subject = "repo:$($Config.GitHubOrg)/${repo}:environment:$($Config.Environment)"

            # Check if already exists
            $existingCred = az ad app federated-credential list --id $appId --query "[?name=='$credName'].name" -o tsv 2>&1
            if ($existingCred -and $existingCred -ne '') {
                Write-Skip "Federated credential $credName already exists"
                continue
            }

            $credParams = @{
                name      = $credName
                issuer    = $OIDC_ISSUER
                subject   = $subject
                audiences = @($OIDC_AUDIENCE)
            } | ConvertTo-Json -Depth 4

            # Write to temp file to avoid PowerShell JSON quoting issues with az cli
            $tempFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempFile -Value $credParams -Encoding utf8
            $credResult = az ad app federated-credential create --id $appId --parameters "@$tempFile" 2>&1
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Failed to create federated credential for $repo — $credResult"
            }
            else {
                Write-Info "  Created: $credName ($subject)"
            }
        }
        Write-Success "Federated credentials configured"

        # --- RBAC Assignments ---
        Write-Step "Creating RBAC role assignments..."
        $subscriptionScope = "/subscriptions/$($Config.SubscriptionId)"

        $roleAssignments = @(
            @{ Role = 'Contributor';                      Scope = $subscriptionScope }
            @{ Role = 'Storage Blob Data Contributor';    Scope = $subscriptionScope }
            @{ Role = 'User Access Administrator';        Scope = $subscriptionScope }
        )

        foreach ($ra in $roleAssignments) {
            Write-Info "  Assigning $($ra.Role)..."
            az role assignment create `
                --assignee-object-id $spObjectId `
                --assignee-principal-type ServicePrincipal `
                --role $ra.Role `
                --scope $ra.Scope `
                --output none 2>&1 | Out-Null
        }
        Write-Success "RBAC roles assigned"

        # --- Update cicd_sp_object_id in env.hcl ---
        $envHclPath = Join-Path $Config.ReposBasePath "radshow-lic" $Config.Environment "env.hcl"
        if (Test-Path $envHclPath) {
            Write-Step "Updating cicd_sp_object_id in env.hcl..."
            $content = Get-Content $envHclPath -Raw
            $content = $content -replace '(cicd_sp_object_id\s*=\s*")[^"]*(")', "`${1}$spObjectId`${2}"
            Set-Content -Path $envHclPath -Value $content -NoNewline

            # Commit the change
            Push-Location (Join-Path $Config.ReposBasePath "radshow-lic")
            $status = git status --porcelain 2>&1
            if ($status) {
                git add -A 2>&1 | Out-Null
                git commit -m "chore: update cicd_sp_object_id for $($Config.Environment)" 2>&1 | Out-Null
            }
            Pop-Location
            Write-Success "cicd_sp_object_id updated"
        }
    }
    else {
        Write-Info "[DRY RUN] Would create App Registration, SP, 5 federated credentials, and 3 RBAC assignments"
    }

    return @{ AppId = $appId; SpObjectId = $spObjectId }
}

#endregion

# ============================================================================
#region Phase: Self-Hosted Runner Infrastructure
# ============================================================================

function Invoke-RunnerInfraPhase {
    param([hashtable]$Config)
    Write-Phase "Runner Infrastructure" "Provisioning self-hosted GitHub runners with Managed Identity"

    $subscriptionScope = "/subscriptions/$($Config.SubscriptionId)"

    # Process both regions
    $regions = @(
        @{
            Location    = $Config.PrimaryLocation
            Short       = $Config.PrimaryShort
            RG          = $Config.ResourceGroupPrimary
            VNet        = "vnet-radshow-$($Config.EnvironmentLower)-$($Config.PrimaryShort)"
            Subnet      = $Config.RunnerSubnetPrimary
            VmssName    = $Config.RunnerVmssNamePrimary
            NatGw       = $Config.RunnerNatGwPrimary
            Nsg         = $Config.RunnerNsgPrimary
        }
        @{
            Location    = $Config.SecondaryLocation
            Short       = $Config.SecondaryShort
            RG          = $Config.ResourceGroupSecondary
            VNet        = "vnet-radshow-$($Config.EnvironmentLower)-$($Config.SecondaryShort)"
            Subnet      = $Config.RunnerSubnetSecondary
            VmssName    = $Config.RunnerVmssNameSecondary
            NatGw       = $Config.RunnerNatGwSecondary
            Nsg         = $Config.RunnerNsgSecondary
        }
    )

    $miPrincipalIds = @{}

    foreach ($region in $regions) {
        Write-Host ""
        Write-Step "--- Setting up runners in $($region.Location) ($($region.Short)) ---"

        # --- Create NSG for runners ---
        Invoke-CommandSafe -Description "Creating NSG $($region.Nsg)..." -Command {
            az network nsg create `
                --name $region.Nsg `
                --resource-group $region.RG `
                --location $region.Location `
                --output none
        }

        # Allow outbound HTTPS (GitHub, Azure ARM, login.microsoftonline.com)
        Invoke-CommandSafe -Description "Adding outbound HTTPS rule..." -Command {
            az network nsg rule create `
                --nsg-name $region.Nsg `
                --resource-group $region.RG `
                --name "AllowOutboundHTTPS" `
                --priority 100 `
                --direction Outbound `
                --access Allow `
                --protocol Tcp `
                --destination-port-ranges 443 `
                --source-address-prefixes "*" `
                --destination-address-prefixes "Internet" `
                --output none
        }
        Write-Success "NSG created"

        # --- Create runner subnet ---
        Write-Step "Creating runner subnet $($region.Subnet) ($($Config.RunnerSubnetCidr))..."
        if (-not $DryRun) {
            $existingSubnet = az network vnet subnet show `
                --vnet-name $region.VNet -g $region.RG --name $region.Subnet 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Skip "Subnet $($region.Subnet) already exists"
            }
            else {
                az network vnet subnet create `
                    --vnet-name $region.VNet `
                    --resource-group $region.RG `
                    --name $region.Subnet `
                    --address-prefixes $Config.RunnerSubnetCidr `
                    --network-security-group $region.Nsg `
                    --output none 2>&1 | Out-Null
                Write-Success "Subnet created"
            }
        }

        # --- Create NAT Gateway for stable outbound IP ---
        Invoke-CommandSafe -Description "Creating public IP for NAT Gateway..." -Command {
            az network public-ip create `
                --name "pip-$($region.NatGw)" `
                --resource-group $region.RG `
                --location $region.Location `
                --sku Standard `
                --allocation-method Static `
                --output none
        }

        Invoke-CommandSafe -Description "Creating NAT Gateway $($region.NatGw)..." -Command {
            az network nat gateway create `
                --name $region.NatGw `
                --resource-group $region.RG `
                --location $region.Location `
                --public-ip-addresses "pip-$($region.NatGw)" `
                --idle-timeout 10 `
                --output none
        }

        # Associate NAT Gateway with runner subnet
        Invoke-CommandSafe -Description "Associating NAT Gateway with runner subnet..." -Command {
            az network vnet subnet update `
                --vnet-name $region.VNet `
                --resource-group $region.RG `
                --name $region.Subnet `
                --nat-gateway $region.NatGw `
                --output none
        }
        Write-Success "NAT Gateway configured"

        # --- Create VMSS for runners ---
        Write-Step "Creating runner VMSS $($region.VmssName)..."
        if (-not $DryRun) {
            $existingVmss = az vmss show --name $region.VmssName -g $region.RG 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Skip "VMSS $($region.VmssName) already exists"
            }
            else {
                # Create VMSS with system-assigned managed identity
                az vmss create `
                    --name $region.VmssName `
                    --resource-group $region.RG `
                    --location $region.Location `
                    --image "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest" `
                    --vm-sku $Config.RunnerVmSize `
                    --instance-count $Config.RunnerCount `
                    --vnet-name $region.VNet `
                    --subnet $region.Subnet `
                    --assign-identity '[system]' `
                    --admin-username "runneradmin" `
                    --generate-ssh-keys `
                    --upgrade-policy-mode Manual `
                    --single-placement-group false `
                    --platform-fault-domain-count 1 `
                    --disable-overprovision `
                    --output none 2>&1 | Out-Null

                if ($LASTEXITCODE -ne 0) {
                    Write-Err "Failed to create VMSS $($region.VmssName)"
                    continue
                }
                Write-Success "VMSS created"
            }

            # Get the MI principal ID
            $principalId = az vmss identity show --name $region.VmssName -g $region.RG `
                --query "principalId" -o tsv 2>&1
            if ($principalId -and $LASTEXITCODE -eq 0) {
                $principalId = $principalId.Trim()
                $miPrincipalIds[$region.Short] = $principalId
                Write-Success "MI Principal ID ($($region.Short)): $principalId"
            }

            # Get the MI client ID (needed for azure/login in workflows)
            $miClientId = az vmss identity show --name $region.VmssName -g $region.RG `
                --query "userAssignedIdentities" -o json 2>&1
            # For system-assigned, client ID comes from the SP
            $miClientId = az ad sp show --id $principalId --query "appId" -o tsv 2>&1
            if ($miClientId -and $LASTEXITCODE -eq 0) {
                $Config["RunnerMiClientId_$($region.Short)"] = $miClientId.Trim()
            }
        }

        # --- Install runner agent via Custom Script Extension ---
        Write-Step "Installing GitHub Actions runner agent on VMSS instances..."
        if (-not $DryRun) {
            # Get a runner registration token from GitHub
            $regToken = gh api "orgs/$($Config.GitHubOrg)/actions/runners/registration-token" `
                --method POST --jq '.token' 2>&1
            if ($LASTEXITCODE -ne 0 -or -not $regToken) {
                Write-Err "Could not get runner registration token. Check gh auth permissions (admin:org scope)."
                Write-Info "You can register runners manually later."
            }
            else {
                $regToken = $regToken.Trim()
                # Build the install script
                $labels = "self-hosted,linux,azure-$($Config.EnvironmentLower),azure-$($region.Short)"
                $installScript = @"
#!/bin/bash
set -e
RUNNER_HOME=/opt/actions-runner
mkdir -p \$RUNNER_HOME && cd \$RUNNER_HOME
# Download latest runner
curl -sL https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64-2.321.0.tar.gz | tar xz
# Install dependencies
./bin/installdependencies.sh
# Configure as org-level runner
RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url https://github.com/$($Config.GitHubOrg) --token $regToken --labels $labels --name \$(hostname)-\$(date +%s) --unattended --replace
# Install and start as service
./svc.sh install
./svc.sh start
# Install required tools
apt-get update && apt-get install -y curl apt-transport-https lsb-release gnupg jq unzip
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
# Terraform
curl -sL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip -o /tmp/tf.zip && unzip -o /tmp/tf.zip -d /usr/local/bin/
# Terragrunt
curl -sL https://github.com/gruntwork-io/terragrunt/releases/download/v1.0.3/terragrunt_linux_amd64 -o /usr/local/bin/terragrunt && chmod +x /usr/local/bin/terragrunt
# Docker
curl -fsSL https://get.docker.com | bash
usermod -aG docker runneradmin
# .NET SDK 8
apt-get install -y dotnet-sdk-8.0 || true
# Node.js LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
"@
                $scriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($installScript))

                az vmss extension set `
                    --vmss-name $region.VmssName `
                    --resource-group $region.RG `
                    --name "CustomScript" `
                    --publisher "Microsoft.Azure.Extensions" `
                    --version "2.1" `
                    --settings "{`"script`":`"$scriptBase64`"}" `
                    --output none 2>&1 | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    # Update instances to apply the extension
                    az vmss update-instances --instance-ids '*' `
                        --name $region.VmssName -g $region.RG --output none 2>&1 | Out-Null
                    Write-Success "Runner agent installed on $($region.VmssName)"
                }
                else {
                    Write-Err "Custom Script Extension failed. Register runners manually."
                }
            }
        }
    }

    # --- Assign RBAC to runner MI (both regions' MIs) ---
    Write-Step "Assigning RBAC roles to runner Managed Identities..."
    if (-not $DryRun) {
        foreach ($shortCode in $miPrincipalIds.Keys) {
            $principalId = $miPrincipalIds[$shortCode]
            $roleAssignments = @(
                @{ Role = 'Contributor';                   Scope = $subscriptionScope }
                @{ Role = 'Storage Blob Data Contributor'; Scope = $subscriptionScope }
                @{ Role = 'User Access Administrator';     Scope = $subscriptionScope }
            )
            foreach ($ra in $roleAssignments) {
                Write-Info "  Assigning $($ra.Role) to MI ($shortCode)..."
                az role assignment create `
                    --assignee-object-id $principalId `
                    --assignee-principal-type ServicePrincipal `
                    --role $ra.Role `
                    --scope $ra.Scope `
                    --output none 2>&1 | Out-Null
            }
        }
        Write-Success "RBAC roles assigned to runner MIs"

        # Store first MI principal ID as cicd_sp_object_id equivalent
        $firstMiPrincipalId = $miPrincipalIds.Values | Select-Object -First 1
        if ($firstMiPrincipalId) {
            $Config['CicdSpObjectId'] = $firstMiPrincipalId

            # Update cicd_sp_object_id in env.hcl
            $envHclPath = Join-Path $Config.ReposBasePath "radshow-lic" $Config.Environment "env.hcl"
            if (Test-Path $envHclPath) {
                Write-Step "Updating cicd_sp_object_id in env.hcl with runner MI..."
                $content = Get-Content $envHclPath -Raw
                $content = $content -replace '(cicd_sp_object_id\s*=\s*")[^"]*(")', "`${1}$firstMiPrincipalId`${2}"
                Set-Content -Path $envHclPath -Value $content -NoNewline

                Push-Location (Join-Path $Config.ReposBasePath "radshow-lic")
                $status = git status --porcelain 2>&1
                if ($status) {
                    git add -A 2>&1 | Out-Null
                    git commit -m "chore: update cicd_sp_object_id with runner MI for $($Config.Environment)" 2>&1 | Out-Null
                }
                Pop-Location
                Write-Success "cicd_sp_object_id updated with runner MI principal ID"
            }
        }
    }

    # --- Verify runners are online ---
    Write-Step "Waiting for runners to come online (this may take a few minutes)..."
    if (-not $DryRun) {
        $maxAttempts = 12
        $attempt = 0
        $runnersOnline = $false
        while ($attempt -lt $maxAttempts -and -not $runnersOnline) {
            $attempt++
            Start-Sleep -Seconds 30
            $runners = gh api "orgs/$($Config.GitHubOrg)/actions/runners" --jq '.runners | length' 2>&1
            if ($LASTEXITCODE -eq 0 -and [int]$runners -gt 0) {
                $runnersOnline = $true
                Write-Success "$runners runner(s) online"
            }
            else {
                Write-Info "  Attempt $attempt/$maxAttempts — no runners online yet..."
            }
        }
        if (-not $runnersOnline) {
            Write-Err "Runners did not come online within 6 minutes."
            Write-Info "Check VMSS status and custom script extension logs."
            Write-Info "You can continue and register runners manually."
        }
    }

    $miClientIdPrimary = $Config["RunnerMiClientId_$($Config.PrimaryShort)"]
    return @{
        MiPrincipalIds = $miPrincipalIds
        MiClientId     = $miClientIdPrimary
    }
}

#endregion

# ============================================================================
#region Phase: GitHub Environments & Secrets
# ============================================================================

function Invoke-GitHubSetupPhase {
    param([hashtable]$Config, [hashtable]$OidcResult, [hashtable]$RunnerInfraResult)
    Write-Phase "GitHub Setup" "Creating environments and setting secrets on all repos"

    # --- Create GitHub Environments ---
    Write-Step "Creating GitHub environment '$($Config.Environment)' on all app repos..."
    foreach ($repo in $APP_REPOS) {
        $fullRepo = "$($Config.GitHubOrg)/$repo"
        if (-not $DryRun) {
            gh api "repos/$fullRepo/environments/$($Config.Environment)" -X PUT --silent 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Info "  Created environment on $repo"
            }
            else {
                Write-Err "  Failed to create environment on $repo"
            }
        }
    }
    Write-Success "Environments created"

    # --- Set Secrets (differs between GitHubHosted / SelfHosted) ---
    if ($Config.RunnerMode -eq 'SelfHosted') {
        # Self-hosted runners use Managed Identity — only SUBSCRIPTION_ID is needed
        Write-Step "Setting GitHub secrets (SelfHosted / Managed Identity)..."
        foreach ($repo in $REPOS) {
            $fullRepo = "$($Config.GitHubOrg)/$repo"
            Write-Info "  Setting AZURE_SUBSCRIPTION_ID on $repo..."
            if (-not $DryRun) {
                gh secret set AZURE_SUBSCRIPTION_ID --env $Config.Environment --body $Config.SubscriptionId --repo $fullRepo 2>&1 | Out-Null
            }
        }
    }
    else {
        # GitHub-hosted runners use OIDC — need CLIENT_ID, TENANT_ID, SUBSCRIPTION_ID
        Write-Step "Setting GitHub secrets (GitHubHosted / OIDC)..."
        $appId = $null
        if ($OidcResult -and $OidcResult.AppId) {
            $appId = $OidcResult.AppId
        }
        elseif (-not $DryRun) {
            # Look up existing App Registration when running GitHubSetup phase standalone
            Write-Step "Looking up existing App Registration for $($Config.SpDisplayName)..."
            $existing = az ad app list --display-name $Config.SpDisplayName --query "[0].appId" -o tsv 2>&1
            if ($existing -and $LASTEXITCODE -eq 0 -and $existing -ne '') {
                $appId = $existing.Trim()
                Write-Info "  Found: $appId"
            }
            else {
                Write-Err "App Registration not found. Run OIDC phase first."
                exit 1
            }
        }
        else {
            $appId = "PLACEHOLDER"
        }

        foreach ($repo in $REPOS) {
            $fullRepo = "$($Config.GitHubOrg)/$repo"
            Write-Info "  Setting secrets on $repo..."
            if (-not $DryRun) {
                gh secret set AZURE_CLIENT_ID --env $Config.Environment --body $appId --repo $fullRepo 2>&1 | Out-Null
                gh secret set AZURE_TENANT_ID --env $Config.Environment --body $Config.TenantId --repo $fullRepo 2>&1 | Out-Null
                gh secret set AZURE_SUBSCRIPTION_ID --env $Config.Environment --body $Config.SubscriptionId --repo $fullRepo 2>&1 | Out-Null
            }
        }
    }

    # radshow-lic specific
    if (-not $DryRun) {
        $licRepo = "$($Config.GitHubOrg)/radshow-lic"
        gh secret set RESOURCE_GROUP --env $Config.Environment --body $Config.ResourceGroupPrimary --repo $licRepo 2>&1 | Out-Null
    }

    # radshow-api specific
    if (-not $DryRun) {
        $apiRepo = "$($Config.GitHubOrg)/radshow-api"
        gh secret set ACR_NAME --env $Config.Environment --body $Config.AcrName --repo $apiRepo 2>&1 | Out-Null
        gh secret set FUNC_APP_NAME --env $Config.Environment --body $Config.FunctionAppPrimary --repo $apiRepo 2>&1 | Out-Null
        gh secret set FUNC_APP_SECONDARY_NAME --env $Config.Environment --body $Config.FunctionAppSecondary --repo $apiRepo 2>&1 | Out-Null
        gh secret set RESOURCE_GROUP --env $Config.Environment --body $Config.ResourceGroupPrimary --repo $apiRepo 2>&1 | Out-Null
        gh secret set RESOURCE_GROUP_SECONDARY --env $Config.Environment --body $Config.ResourceGroupSecondary --repo $apiRepo 2>&1 | Out-Null
        gh secret set CONTAINER_APP_NAME --env $Config.Environment --body $Config.ContainerAppPrimary --repo $apiRepo 2>&1 | Out-Null
        gh secret set CONTAINER_APP_SECONDARY_NAME --env $Config.Environment --body $Config.ContainerAppSecondary --repo $apiRepo 2>&1 | Out-Null
    }

    # radshow-spa specific
    if (-not $DryRun) {
        $spaRepo = "$($Config.GitHubOrg)/radshow-spa"
        gh secret set STORAGE_ACCOUNT_NAME --env $Config.Environment --body $Config.StorageAccountPrimary --repo $spaRepo 2>&1 | Out-Null
        gh secret set STORAGE_ACCOUNT_SECONDARY_NAME --env $Config.Environment --body $Config.StorageAccountSecondary --repo $spaRepo 2>&1 | Out-Null
        gh secret set RESOURCE_GROUP --env $Config.Environment --body $Config.ResourceGroupPrimary --repo $spaRepo 2>&1 | Out-Null
        gh secret set FRONT_DOOR_RESOURCE_GROUP --env $Config.Environment --body $Config.ResourceGroupPrimary --repo $spaRepo 2>&1 | Out-Null
        gh secret set FRONT_DOOR_PROFILE_NAME --env $Config.Environment --body $Config.FrontDoorProfile --repo $spaRepo 2>&1 | Out-Null
        gh secret set FRONT_DOOR_ENDPOINT_NAME --env $Config.Environment --body $Config.FrontDoorEndpoint --repo $spaRepo 2>&1 | Out-Null
    }

    # radshow-apim specific
    if (-not $DryRun) {
        $apimRepo = "$($Config.GitHubOrg)/radshow-apim"
        gh secret set RESOURCE_GROUP --env $Config.Environment --body $Config.ResourceGroupPrimary --repo $apimRepo 2>&1 | Out-Null
        gh secret set APIM_NAME --env $Config.Environment --body $Config.ApimName --repo $apimRepo 2>&1 | Out-Null
        gh secret set AZURE_RESOURCE_GROUP_NAME --env $Config.Environment --body $Config.ResourceGroupPrimary --repo $apimRepo 2>&1 | Out-Null
        gh secret set API_MANAGEMENT_SERVICE_NAME --env $Config.Environment --body $Config.ApimName --repo $apimRepo 2>&1 | Out-Null
    }

    # radshow-db specific
    if (-not $DryRun) {
        $dbRepo = "$($Config.GitHubOrg)/radshow-db"
        gh secret set FUNC_APP_NAME --env $Config.Environment --body $Config.FunctionAppPrimary --repo $dbRepo 2>&1 | Out-Null
        gh secret set FUNC_APP_SECONDARY_NAME --env $Config.Environment --body $Config.FunctionAppSecondary --repo $dbRepo 2>&1 | Out-Null
        gh secret set APP_SERVICE_NAME --env $Config.Environment --body $Config.AppServicePrimary --repo $dbRepo 2>&1 | Out-Null
        gh secret set APP_SERVICE_SECONDARY_NAME --env $Config.Environment --body $Config.AppServiceSecondary --repo $dbRepo 2>&1 | Out-Null
        gh secret set CONTAINER_APP_NAME --env $Config.Environment --body $Config.ContainerAppPrimary --repo $dbRepo 2>&1 | Out-Null
        gh secret set CONTAINER_APP_SECONDARY_NAME --env $Config.Environment --body $Config.ContainerAppSecondary --repo $dbRepo 2>&1 | Out-Null
        gh secret set SQL_DATABASE_NAME --env $Config.Environment --body $Config.SqlDatabaseName --repo $dbRepo 2>&1 | Out-Null
        # SQL_MI_FQDN is set in PostInfra phase after infrastructure provides the FOG listener FQDN
    }

    Write-Success "All GitHub secrets configured"
}

#endregion

# ============================================================================
#region Phase: Infrastructure Deployment
# ============================================================================

function Invoke-InfraPhase {
    param([hashtable]$Config)
    Write-Phase "Infrastructure" "Running terragrunt apply in radshow-lic/$($Config.Environment)"

    $licEnvPath = Join-Path $Config.ReposBasePath "radshow-lic" $Config.Environment

    if (-not (Test-Path $licEnvPath)) {
        Write-Err "Path not found: $licEnvPath"
        exit 1
    }

    # Push local config changes first
    Write-Step "Pushing configuration changes to GitHub..."
    if (-not $DryRun) {
        Push-Location (Join-Path $Config.ReposBasePath "radshow-lic")
        $status = git status --porcelain 2>&1
        if ($status) {
            git add -A 2>&1 | Out-Null
            git commit -m "chore: bootstrap config for $($Config.Environment)" 2>&1 | Out-Null
        }
        git push origin main 2>&1 | Out-Null
        Pop-Location
        Write-Success "radshow-lic pushed"
    }

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  WARNING: Infrastructure deployment can take 2-6 hours" -ForegroundColor Yellow
    Write-Host "  (SQL Managed Instance alone takes 4-6 hours)" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host ""

    if (-not $DryRun) {
        $confirm = Read-Host "  Start infrastructure deployment now? (Y/n)"
        if ($confirm -and $confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Info "Skipped. Re-run with -Phase Infra when ready."
            Write-Info "Remaining phases (PostInfra, Deploy, PostDeploy, Verify) also skipped."
            return 'SKIPPED'
        }
    }

    Write-Step "Running terragrunt run-all apply in $licEnvPath..."
    if (-not $DryRun) {
        try {
            # Use --working-dir to avoid issues with spaces in path via Push-Location
            & terragrunt run-all apply --non-interactive --working-dir "$licEnvPath"
            if ($LASTEXITCODE -ne 0) {
                Write-Err "terragrunt apply failed with exit code $LASTEXITCODE"
                Write-Info "Check the output above for details."
                Write-Info "You can also run manually:"
                Write-Info "  cd '$licEnvPath'"
                Write-Info "  terragrunt run-all apply --non-interactive"
                throw "terragrunt apply failed with exit code $LASTEXITCODE"
            }
        }
        catch {
            throw
        }
    }

    Write-Success "Infrastructure deployment complete"
}

#endregion

# ============================================================================
#region Phase: Post-Infrastructure Secrets
# ============================================================================

function Invoke-PostInfraPhase {
    param([hashtable]$Config)
    Write-Phase "Post-Infrastructure" "Reading terragrunt outputs and setting remaining GitHub secrets"

    $licEnvPath = Join-Path $Config.ReposBasePath "radshow-lic" $Config.Environment
    $dbRepo = "$($Config.GitHubOrg)/radshow-db"

    # --- Get SQL MI FOG Listener FQDN ---
    Write-Step "Reading SQL MI FOG listener FQDN from terragrunt output..."
    $fogFqdn = $null
    if (-not $DryRun) {
        Push-Location (Join-Path $licEnvPath "sql-mi-fog")
        try {
            $fogFqdn = (terragrunt output -raw listener_fqdn 2>&1).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $fogFqdn) {
                Write-Err "Could not read FOG listener FQDN. You may need to set SQL_MI_FQDN manually."
                $fogFqdn = Read-Parameter -Prompt "Enter SQL MI FOG listener FQDN manually" -Required
            }
        }
        finally {
            Pop-Location
        }
        Write-Success "FOG FQDN: $fogFqdn"

        Write-Step "Setting SQL_MI_FQDN on radshow-db..."
        gh secret set SQL_MI_FQDN --env $Config.Environment --body $fogFqdn --repo $dbRepo 2>&1 | Out-Null
        Write-Success "SQL_MI_FQDN set"
    }

    Write-Success "Post-infrastructure secrets configured"
}

#endregion

# ============================================================================
#region Phase: Application Deployment (CI/CD)
# ============================================================================

function Invoke-DeployPhase {
    param([hashtable]$Config)
    Write-Phase "Application Deployment" "Enabling Actions and triggering pipelines in order"

    # --- Verify self-hosted runners are online (SelfHosted mode only) ---
    if ($Config.RunnerMode -eq 'SelfHosted' -and -not $DryRun) {
        Write-Step "Verifying self-hosted runners are online..."
        $runners = gh api "orgs/$($Config.GitHubOrg)/actions/runners" --jq '[.runners[] | select(.status=="online")] | length' 2>&1
        if ($LASTEXITCODE -eq 0 -and [int]$runners -gt 0) {
            Write-Success "$runners self-hosted runner(s) online"
        }
        else {
            Write-Err "No self-hosted runners are online."
            Write-Info "Workflows will queue until a runner is available."
            $cont = Read-Host "  Continue anyway? (Y/n)"
            if ($cont -and $cont -ne 'Y' -and $cont -ne 'y') { exit 1 }
        }
    }

    # --- Enable GitHub Actions on forked repos ---
    Write-Step "Enabling GitHub Actions on forked repos..."
    foreach ($repo in $PIPELINE_REPOS) {
        $fullRepo = "$($Config.GitHubOrg)/$repo"
        if (-not $DryRun) {
            # Enable Actions via API
            gh api "repos/$fullRepo/actions/permissions" -X PUT `
                -f enabled=true -f allowed_actions=all --silent 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Info "  Enabled Actions on $repo"
            }
            else {
                Write-Err "  Could not enable Actions on $repo — enable manually via Actions tab"
            }
        }
    }
    Write-Success "GitHub Actions enabled"

    # --- Push configuration changes to all app repos (triggers pipelines) ---
    $workflowMap = @{
        'radshow-db'   = 'migrate.yml'
        'radshow-api'  = 'deploy.yml'
        'radshow-apim' = 'publisher.yml'
        'radshow-spa'  = 'deploy.yml'
    }

    foreach ($repo in $PIPELINE_REPOS) {
        $fullRepo = "$($Config.GitHubOrg)/$repo"
        $workflow = $workflowMap[$repo]
        $repoPath = Join-Path $Config.ReposBasePath $repo

        Write-Host ""
        Write-Step "Triggering $repo ($workflow)..."

        if (-not $DryRun) {
            if (-not (Test-Path $repoPath)) {
                Write-Err "$repo not found at $repoPath"
                continue
            }

            # Push any pending changes (or make a trigger commit)
            Push-Location $repoPath
            $status = git status --porcelain 2>&1
            if (-not $status) {
                # No changes — make a trigger commit
                $readmePath = Join-Path $repoPath "README.md"
                if (Test-Path $readmePath) {
                    Add-Content -Path $readmePath -Value "`n"
                }
                else {
                    Set-Content -Path (Join-Path $repoPath ".trigger") -Value (Get-Date -Format o)
                }
                git add -A 2>&1 | Out-Null
                git commit -m "chore: trigger initial $($Config.Environment) deployment" 2>&1 | Out-Null
            }
            else {
                git add -A 2>&1 | Out-Null
                git commit -m "chore: configure for $($Config.Environment) environment" 2>&1 | Out-Null
            }
            git push origin main 2>&1 | Out-Null
            Pop-Location
            Write-Success "Pushed to $repo"

            # Wait for the workflow run to appear
            Write-Step "Waiting for $workflow run to start..."
            Start-Sleep -Seconds 15

            # Find the latest run
            $runId = gh run list --repo $fullRepo --workflow $workflow --limit 1 --json databaseId --jq '.[0].databaseId' 2>&1
            if ($LASTEXITCODE -ne 0 -or -not $runId) {
                Write-Err "Could not find workflow run for $workflow on $repo"
                Write-Info "Check manually: https://github.com/$fullRepo/actions"
                $skip = Read-Host "  Continue to next repo? (Y/n)"
                if ($skip -and $skip -ne 'Y' -and $skip -ne 'y') { exit 1 }
                continue
            }

            Write-Step "Watching run $runId..."
            gh run watch $runId --repo $fullRepo --exit-status 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "$repo pipeline FAILED. Check: https://github.com/$fullRepo/actions/runs/$runId"
                $skip = Read-Host "  Continue to next repo anyway? (Y/n)"
                if ($skip -and $skip -ne 'Y' -and $skip -ne 'y') { exit 1 }
            }
            else {
                Write-Success "$repo pipeline completed successfully"
            }
        }
    }

    Write-Success "All application pipelines triggered"
}

#endregion

# ============================================================================
#region Phase: Post-Deployment Setup
# ============================================================================

function Invoke-PostDeployPhase {
    param([hashtable]$Config)
    Write-Phase "Post-Deployment" "Seeding Key Vault secrets, RBAC upgrades, and DNS zone verification"

    # --- Seed Key Vault Secrets ---
    foreach ($kvName in @($Config.KeyVaultPrimary, $Config.KeyVaultSecondary)) {
        $rg = if ($kvName -eq $Config.KeyVaultPrimary) { $Config.ResourceGroupPrimary } else { $Config.ResourceGroupSecondary }

        Write-Step "Temporarily enabling public access on $kvName..."
        if (-not $DryRun) {
            az keyvault update --name $kvName -g $rg `
                --public-network-access enabled --default-action Allow --output none 2>&1 | Out-Null
            Start-Sleep -Seconds 5
        }

        Write-Step "Setting Key Vault secrets on $kvName..."
        if (-not $DryRun) {
            az keyvault secret set --vault-name $kvName `
                --name "active-region" --value $Config.PrimaryLocation --output none 2>&1 | Out-Null
            az keyvault secret set --vault-name $kvName `
                --name "failover-password" --value $Config.DRPassword --output none 2>&1 | Out-Null
            Write-Success "Secrets set on $kvName"
        }

        Write-Step "Locking down $kvName (disabling public access)..."
        if (-not $DryRun) {
            az keyvault update --name $kvName -g $rg `
                --public-network-access disabled --output none 2>&1 | Out-Null
            Write-Success "$kvName locked down"
        }
    }

    # --- RBAC: Upgrade Function App MI to Key Vault Secrets Officer ---
    Write-Step "Upgrading Function App managed identities to Key Vault Secrets Officer..."
    foreach ($funcApp in @($Config.FunctionAppPrimary, $Config.FunctionAppSecondary)) {
        $rg = if ($funcApp -eq $Config.FunctionAppPrimary) { $Config.ResourceGroupPrimary } else { $Config.ResourceGroupSecondary }
        if (-not $DryRun) {
            $principalId = az functionapp identity show --name $funcApp -g $rg --query principalId -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and $principalId) {
                $principalId = $principalId.Trim()
                # Assign on both Key Vaults
                foreach ($kvName in @($Config.KeyVaultPrimary, $Config.KeyVaultSecondary)) {
                    $kvRg = if ($kvName -eq $Config.KeyVaultPrimary) { $Config.ResourceGroupPrimary } else { $Config.ResourceGroupSecondary }
                    $kvScope = "/subscriptions/$($Config.SubscriptionId)/resourceGroups/$kvRg/providers/Microsoft.KeyVault/vaults/$kvName"
                    az role assignment create `
                        --assignee-object-id $principalId `
                        --assignee-principal-type ServicePrincipal `
                        --role "Key Vault Secrets Officer" `
                        --scope $kvScope `
                        --output none 2>&1 | Out-Null
                }
                Write-Info "  $funcApp MI ($principalId) -> Key Vault Secrets Officer on both KVs"
            }
            else {
                Write-Err "Could not get identity for $funcApp"
            }
        }
    }
    Write-Success "RBAC upgrades complete"

    # --- Verify Container App Private DNS Zones ---
    Write-Step "Checking Container App Environment private DNS zones..."
    foreach ($region in @(
        @{ Short = $Config.PrimaryShort; RG = $Config.ResourceGroupPrimary; VNet = "vnet-radshow-$($Config.EnvironmentLower)-$($Config.PrimaryShort)" }
        @{ Short = $Config.SecondaryShort; RG = $Config.ResourceGroupSecondary; VNet = "vnet-radshow-$($Config.EnvironmentLower)-$($Config.SecondaryShort)" }
    )) {
        if (-not $DryRun) {
            # Find Container App Environment in the resource group
            $caeList = az containerapp env list -g $region.RG --query "[0]" -o json 2>&1
            if ($LASTEXITCODE -eq 0 -and $caeList -ne '[]' -and $caeList -ne '') {
                $cae = $caeList | ConvertFrom-Json
                $caeDomain = $cae.properties.defaultDomain
                $caeIp = $cae.properties.staticIp

                if ($caeDomain -and $caeIp) {
                    # Check if private DNS zone exists
                    $zoneExists = az network private-dns zone show -g $region.RG --name $caeDomain 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Step "Creating private DNS zone: $caeDomain..."
                        az network private-dns zone create -g $region.RG --name $caeDomain --output none 2>&1 | Out-Null
                        az network private-dns record-set a add-record -g $region.RG --zone-name $caeDomain `
                            --record-set-name "*" --ipv4-address $caeIp --output none 2>&1 | Out-Null
                        az network private-dns record-set a add-record -g $region.RG --zone-name $caeDomain `
                            --record-set-name "@" --ipv4-address $caeIp --output none 2>&1 | Out-Null

                        # Link to both VNets
                        $primaryVnet = "vnet-radshow-$($Config.EnvironmentLower)-$($Config.PrimaryShort)"
                        $secondaryVnet = "vnet-radshow-$($Config.EnvironmentLower)-$($Config.SecondaryShort)"
                        $primaryVnetId = "/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroupPrimary)/providers/Microsoft.Network/virtualNetworks/$primaryVnet"
                        $secondaryVnetId = "/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroupSecondary)/providers/Microsoft.Network/virtualNetworks/$secondaryVnet"

                        az network private-dns link vnet create -g $region.RG --zone-name $caeDomain `
                            --name "link-vnet-primary" --virtual-network $primaryVnetId --registration-enabled false --output none 2>&1 | Out-Null
                        az network private-dns link vnet create -g $region.RG --zone-name $caeDomain `
                            --name "link-vnet-secondary" --virtual-network $secondaryVnetId --registration-enabled false --output none 2>&1 | Out-Null

                        Write-Success "DNS zone created for $caeDomain"
                    }
                    else {
                        Write-Skip "DNS zone $caeDomain already exists"
                    }
                }
            }
            else {
                Write-Skip "No Container App Environment found in $($region.RG)"
            }
        }
    }

    Write-Success "Post-deployment setup complete"
}

#endregion

# ============================================================================
#region Phase: Verification
# ============================================================================

function Invoke-VerifyPhase {
    param([hashtable]$Config)
    Write-Phase "Verification" "Testing all Front Door routes and backend health"

    if (-not $DryRun) {
        # Get Front Door endpoint hostname
        Write-Step "Looking up Front Door endpoint hostname..."
        $fdEndpoints = az afd endpoint list --profile-name $Config.FrontDoorProfile `
            -g $Config.ResourceGroupPrimary --query "[?name=='$($Config.FrontDoorEndpoint)'].hostName" -o tsv 2>&1

        if ($LASTEXITCODE -ne 0 -or -not $fdEndpoints) {
            Write-Err "Could not find Front Door endpoint. Check manually."
            return
        }
        $fdHostname = $fdEndpoints.Trim()
        Write-Info "Front Door hostname: $fdHostname"

        $tests = @(
            @{ Name = "SPA (root)";      Url = "https://$fdHostname/" }
            @{ Name = "API status";      Url = "https://$fdHostname/api/status" }
            @{ Name = "API products";    Url = "https://$fdHostname/api/products" }
            @{ Name = "API healthz";     Url = "https://$fdHostname/api/healthz" }
        )

        Write-Host ""
        foreach ($test in $tests) {
            Write-Step "Testing: $($test.Name) — $($test.Url)"
            try {
                $response = Invoke-WebRequest -Uri $test.Url -UseBasicParsing -TimeoutSec 30 -ErrorAction SilentlyContinue
                $status = $response.StatusCode
                if ($status -ge 200 -and $status -lt 400) {
                    Write-Success "$($test.Name): HTTP $status"
                }
                else {
                    Write-Err "$($test.Name): HTTP $status"
                }
            }
            catch {
                $errorStatus = $_.Exception.Response.StatusCode.value__
                if ($errorStatus) {
                    Write-Err "$($test.Name): HTTP $errorStatus"
                }
                else {
                    Write-Err "$($test.Name): $($_.Exception.Message)"
                }
            }
        }

        # Direct backend health checks
        Write-Host ""
        Write-Step "Testing direct backend health..."
        foreach ($funcApp in @($Config.FunctionAppPrimary, $Config.FunctionAppSecondary)) {
            $url = "https://$funcApp.azurewebsites.net/api/healthz"
            try {
                $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction SilentlyContinue
                Write-Success "$funcApp healthz: HTTP $($response.StatusCode)"
            }
            catch {
                Write-Err "$funcApp healthz: unreachable (may be expected if public access is off)"
            }
        }
    }

    Write-Host ""
    Write-Success "Verification complete"
}

#endregion

# ============================================================================
#region Main Execution
# ============================================================================

$startTime = Get-Date
$logFile = "bootstrap-$($Phase.ToLower())-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Start transcript for logging
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }

Write-Host ""
Write-Host "  RAD Showcase Bootstrap" -ForegroundColor Magenta
Write-Host "  Phase: $Phase | RunnerMode: $RunnerMode | DryRun: $DryRun" -ForegroundColor DarkMagenta
Write-Host ""

# Collect configuration
$config = Get-BootstrapConfig

# Determine which phases to run
$phaseOrder = if ($RunnerMode -eq 'SelfHosted') { $PHASE_ORDER_SELF_HOSTED } else { $PHASE_ORDER_GITHUB_HOSTED }
$phasesToRun = if ($Phase -eq 'All') { $phaseOrder } else { @($Phase) }

# Execute phases
$oidcResult = $null
$runnerInfraResult = $null
foreach ($p in $phasesToRun) {
    try {
        $phaseResult = $null
        switch ($p) {
            'Prereqs'      { Invoke-PrereqsPhase -Config $config }
            'ForkClone'    { Invoke-ForkClonePhase -Config $config }
            'Configure'    { Invoke-ConfigurePhase -Config $config }
            'TFState'      { Invoke-TFStatePhase -Config $config }
            'OIDC'         { $oidcResult = Invoke-OIDCPhase -Config $config }
            'RunnerInfra'  { $runnerInfraResult = Invoke-RunnerInfraPhase -Config $config }
            'GitHubSetup'  { Invoke-GitHubSetupPhase -Config $config -OidcResult $oidcResult -RunnerInfraResult $runnerInfraResult }
            'Infra'        { $phaseResult = Invoke-InfraPhase -Config $config }
            'PostInfra'    { Invoke-PostInfraPhase -Config $config }
            'Deploy'       { Invoke-DeployPhase -Config $config }
            'PostDeploy'   { Invoke-PostDeployPhase -Config $config }
            'Verify'       { Invoke-VerifyPhase -Config $config }
        }
        if ($phaseResult -eq 'SKIPPED') {
            Write-Host ""
            Write-Host "  Pipeline stopped. Resume later with: .\bootstrap-environment.ps1 -Phase $p" -ForegroundColor Yellow
            break
        }
    }
    catch {
        Write-Host ""
        Write-Err "Phase '$p' failed: $($_.Exception.Message)"
        Write-Err "Re-run with: .\bootstrap-environment.ps1 -Phase $p"
        Write-Host ""
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
}

$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host "  Bootstrap Complete!" -ForegroundColor Green
Write-Host "  Elapsed: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "  Log: $logFile" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Green

try { Stop-Transcript | Out-Null } catch { }

#endregion
