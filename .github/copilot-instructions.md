# RAD Showcase — Copilot Instructions

## Project Overview

This is `radshow-def`, a Terraform module library for the RAD Showcase multi-region Azure application. It contains 16+ reusable modules under `modules/` that are consumed by Terragrunt lifecycle configs in the `radshow-lic` repository.

## Architecture

- **Primary region**: swedencentral (swc)
- **Secondary region**: germanywestcentral (gwc)
- **Naming convention**: `{type}-radshow-{env}` or `{type}radshow{env}`
- **DR strategy**: Active-passive with SQL MI failover groups, geo-replicated ACR, RA-GZRS storage

## Key Resources

- Azure Front Door (Premium) → Application Gateway (WAF_v2) → APIM → Function App / Storage SPA
- SQL Managed Instance with failover groups
- Container Registry (Premium, geo-replicated)
- Redis Cache (Premium)
- Key Vault per region
- VNet per region with 8 subnets

## Module Conventions

Each module follows: `modules/<name>/main.tf`, `variables.tf`, `outputs.tf`

- All variables must have `type` and `description`
- Use Managed Identities over service principals
- Prefer implicit dependencies over `depends_on`
- Support multi-region via `location` variable
- All changes must be codified in Terraform — no manual Azure portal changes

## Related Repositories

| Repo | Purpose |
|------|---------|
| radshow-lic | Terragrunt lifecycle configs (DEV01/STG01/PRD01) |
| radshow-spa | Vue 3 + Vite SPA |
| radshow-api | .NET 8 Azure Functions API (containerized) |
| radshow-apim | APIOps APIM config |
| radshow-db | SQL MI schema migrations |
