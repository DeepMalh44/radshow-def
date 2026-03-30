# RAD Showcase — New Environment Deployment Runbook

This document covers the complete steps to deploy a new environment (e.g., DEV02, STG02) from scratch.

---

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Terragrunt installed
- Access to GitHub org `DeepMalh44` with admin permissions
- Azure subscription with sufficient quota (SQL MI vCores, ACR Premium, etc.)

---

## Step 1: Create Environment Config in `radshow-lic`

### 1.1 Create the environment folder

Copy an existing environment folder as template:
```bash
cp -r DEV01 DEV02    # or whatever env name
```

### 1.2 Edit `env.hcl`

Update environment-specific values:
```hcl
locals {
  environment        = "DEV02"
  name_prefix        = "radshow-dev02"
  subscription_id    = "YOUR-SUBSCRIPTION-ID"
  primary_location   = "swedencentral"     # change as needed
  secondary_location = "germanywestcentral" # change as needed
  enable_dr          = false               # true for STG/PRD
  enable_waf         = false               # true for PRD
  # ... SKU sizes, feature flags
}
```

### 1.3 Verify Terragrunt configs

Each subfolder (resource-group, networking, function-app, etc.) should reference `_envcommon/*.hcl` includes. The `_envcommon/` configs are shared and generally don't need changes.

---

## Step 2: Set Up OIDC for CI/CD

Run the setup script (creates Entra App Registration, federated credentials, GitHub secrets):

```bash
cd radshow-lic/scripts
bash setup-github-oidc.sh --env DEV02 --org DeepMalh44
```

This creates:
- Entra App Registration: `sp-radshow-cicd-dev02`
- Federated credentials for: `radshow-lic`, `radshow-spa`, `radshow-api`, `radshow-apim`
- GitHub environment `DEV02` with secrets:
  - `AZURE_CLIENT_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
  - `ACR_NAME`
  - `FUNC_APP_NAME`
  - `RESOURCE_GROUP`

### Manual alternative (if script fails due to Graph API issues)

```bash
# Create app registration
az ad app create --display-name "sp-radshow-cicd-dev02"

# Get app ID
APP_ID=$(az ad app list --display-name "sp-radshow-cicd-dev02" --query "[0].appId" -o tsv)

# Create service principal
az ad sp create --id $APP_ID

# Add federated credentials (repeat per repo)
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "radshow-api-dev02",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:DeepMalh44/radshow-api:environment:DEV02",
  "audiences": ["api://AzureADTokenExchange"]
}'

# Assign Contributor on resource group (after terragrunt creates it)
SP_OID=$(az ad sp show --id $APP_ID --query id -o tsv)
az role assignment create --assignee-object-id $SP_OID --assignee-principal-type ServicePrincipal \
  --role Contributor --scope "/subscriptions/{sub-id}/resourceGroups/rg-radshow-dev02-{region}"
```

> **Known issue**: `az ad` commands may fail with `TokenCreatedWithOutdatedPolicies`. Workaround: decode the ARM JWT token to extract your user OID and use `--assignee-object-id` directly.

---

## Step 3: Deploy Infrastructure with Terragrunt

```bash
cd radshow-lic/DEV02

# Plan first
terragrunt run-all plan

# Apply (creates all Azure resources)
terragrunt run-all apply
```

### What Terragrunt creates automatically:
- Resource groups (primary + secondary if DR enabled)
- VNet + subnets + NSGs + private DNS zones
- VNet peering (if 2 regions)
- Front Door Premium with single `ep-spa` endpoint + WAF policy
- APIM (Premium Classic, multi-region if enabled)
- Function App with `container_registry_use_managed_identity = true`
- App Service Plan (EP1)
- Container App Environment + Container Apps
- ACR (Premium, geo-replicated if enabled)
- SQL MI + failover group
- Redis (Premium, geo-replicated if enabled)
- Key Vault (per region)
- Storage (RA-GZRS, static website enabled)
- Private endpoints for all PaaS services
- Monitoring (Log Analytics + App Insights)
- Automation Account (DR runbooks)
- **RBAC role assignments** including:
  - Function App MI → Key Vault Secrets User
  - Function App MI → Storage Blob Data Contributor
  - Function App MI → **AcrPull** on ACR
  - (Same for App Service MI and secondary region identities)

---

## Step 4: Deploy the SPA

Push to `radshow-spa` main branch (or trigger workflow_dispatch for the new environment):

```bash
cd radshow-spa
# CI/CD handles: npm build → upload to $web → purge Front Door cache
git push origin main
```

### Manual deploy (if CI/CD not ready):
```bash
cd radshow-spa
npm ci && npm run build

# Upload to storage
az storage blob upload-batch \
  --account-name stradshowdev02swc \
  --destination '$web' \
  --source dist/ \
  --overwrite \
  --auth-mode login

# Purge Front Door cache
az afd endpoint purge \
  --resource-group rg-radshow-dev02-swc \
  --profile-name afd-radshow-dev02 \
  --endpoint-name ep-spa \
  --content-paths "/*"
```

---

## Step 5: Deploy the API

Push to `radshow-api` main branch (or trigger workflow_dispatch):

```bash
cd radshow-api
git push origin main
```

### Manual deploy (if CI/CD not ready):
```bash
cd radshow-api

# Build in ACR (cloud-based, no local Docker needed)
az acr build --registry acrradshowdev02 \
  --image "radshow-api:latest" \
  --image "radshow-api:dev02" \
  --file Dockerfile .

# Deploy container to Function App
az functionapp config container set \
  --name func-radshow-dev02 \
  --resource-group rg-radshow-dev02-swc \
  --image "acrradshowdev02.azurecr.io/radshow-api:dev02" \
  --registry-server "acrradshowdev02.azurecr.io"

# Restart to pull new image
az functionapp restart --name func-radshow-dev02 --resource-group rg-radshow-dev02-swc
```

> `.dockerignore` is already in the repo — excludes `bin/`, `obj/`, `.git` to prevent ACR build failures.

---

## Step 6: Deploy APIM Configuration

```bash
cd radshow-apim
# APIOps publisher pipeline handles API definitions + policies
git push origin main
```

---

## Step 7: Deploy Database Schema

```bash
cd radshow-db
# Run migrations against SQL MI
# Connection uses Managed Identity from a jumpbox or pipeline agent in the VNet
sqlcmd -S sqlmi-radshow-dev02.{hash}.database.windows.net -d radshowdb -G -i migrations/V001__create_products_table.sql
sqlcmd -S sqlmi-radshow-dev02.{hash}.database.windows.net -d radshowdb -G -i migrations/V002__seed_sample_data.sql
```

---

## Step 8: Verify End-to-End

```bash
# Health check (direct)
curl https://func-radshow-dev02.azurewebsites.net/api/healthz
# Expected: 200 "Healthy"

# Health check (via Front Door)
curl https://ep-spa-{hash}.{zone}.azurefd.net/api/healthz
# Expected: 200 "Healthy"

# Regional status
curl https://ep-spa-{hash}.{zone}.azurefd.net/api/status
# Expected: 200 JSON with component health (SQL MI, Redis, FunctionApp)

# SPA
curl -sI https://ep-spa-{hash}.{zone}.azurefd.net/
# Expected: 200 with HTML containing "RAD Showcase"
```

---

## Troubleshooting

### Function App returning 503 (no code deployed)
Container image isn't set or can't be pulled. Check:
```bash
az functionapp config container show --name func-radshow-dev02 --resource-group rg-radshow-dev02-swc
az webapp log download --name func-radshow-dev02 --resource-group rg-radshow-dev02-swc --log-file logs.zip
```

### Function App 500 on healthz
Check container logs for `Synchronous operations are disallowed` — ensure `WriteStringAsync` is used (fixed in commit `2c20979`).

### ACR build fails with NuGet fallback path
Ensure `.dockerignore` exists in repo root and excludes `bin/` and `obj/`.

### Front Door /api/* returns 404 or SPA HTML
Check that `route-api` exists on `ep-spa` endpoint (not a separate `ep-api` endpoint):
```bash
az afd route list --profile-name afd-radshow-dev02 --resource-group rg-radshow-dev02-swc --endpoint-name ep-spa -o table
```

### Function App can't pull from ACR
Verify:
1. `acrUseManagedIdentityCreds` is true: `az resource show --ids {func-app-id}/config/web --query properties.acrUseManagedIdentityCreds`
2. AcrPull role exists: `az role assignment list --scope {acr-id} --assignee {func-mi-principal-id}`

### Azure CLI Graph API errors (TokenCreatedWithOutdatedPolicies)
This is a CAE token policy issue. Workaround:
```bash
# Get your OID from ARM token
az account get-access-token --query accessToken -o tsv | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['oid'])"

# Use --assignee-object-id instead of --assignee
az role assignment create --assignee-object-id {YOUR_OID} --assignee-principal-type User --role "Storage Blob Data Contributor" --scope {resource-id}
```
