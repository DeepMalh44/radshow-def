# RAD Showcase App — Infrastructure Definitions (`radshow-def`)

## Overview

This repository contains all reusable Terraform modules for the RAD Showcase Application.
It is the infrastructure **blueprint** — no environment-specific values live here.

Environments are deployed via [radshow-lic](https://github.com/DeepMalh44/radshow-lic) (the lifecycle controller),
which references a pinned version of this repo and supplies environment-specific variables.

## Module Inventory

| Module | Description |
|---|---|
| `resource-group` | Resource groups with optional resource locks (IR-02) |
| `networking` | VNet, Subnets, NSGs, Private DNS Zones |
| `vnet-peering` | Bidirectional VNet peering between regions |
| `front-door` | Azure Front Door Premium + WAF (active-passive routing) |
| `apim` | API Management Premium Classic with multi-region gateway |
| `app-service` | App Service Plans for Functions hosting |
| `function-app` | Azure Functions on Elastic Premium plans |
| `container-apps` | ACA Environment + Container Apps |
| `container-instances` | Azure Container Instances |
| `container-registry` | ACR with geo-replication |
| `sql-mi` | SQL Managed Instance + Failover Groups |
| `redis` | Redis Cache Premium + Geo-Replication |
| `key-vault` | Key Vault with RBAC + Private Endpoints |
| `storage` | Storage Accounts (RA-GZRS) + static website hosting |
| `private-endpoint` | Reusable Private Endpoint module |
| `monitoring` | Log Analytics + App Insights + DR Alerts |
| `automation` | Azure Automation for DR failover runbooks |
| `role-assignments` | Centralized RBAC assignments |

## Region Configurability

All modules accept `location` as an input variable. Region-specific behavior (AZ support,
SKU availability, replication types) is handled via capability lookups in the consuming
Terragrunt configuration. No module contains hardcoded region names.

## Usage

These modules are not invoked directly. They are consumed by `radshow-lic` via Terragrunt:

```hcl
# Example from radshow-lic/PRD01/resource-group/terragrunt.hcl
terraform {
  source = "git::https://github.com/DeepMalh44/radshow-def.git//modules/resource-group?ref=v1.0.0"
}
```

## Prerequisites

- Terraform >= 1.5.0
- AzureRM provider ~> 3.80
- AzAPI provider >= 1.12.0
