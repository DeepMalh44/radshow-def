---
applyTo: '**/*.tf,**/*.tfvars,**/*.tflint.hcl'
description: 'Azure-specific Terraform best practices for the radshow-def module library.'
---

# Azure Terraform Best Practices

## 1. Overview

These instructions provide Azure-specific guidance for Terraform modules in the radshow-def repository. This is a reusable module library consumed by Terragrunt lifecycle configs in radshow-lic.

## 2. Anti-Patterns to Avoid

**Configuration:**
- MUST NOT hardcode values that should be parameterized
- SHOULD NOT use `terraform import` as a regular workflow pattern
- MUST NOT use `local-exec` provisioners unless absolutely necessary

**Security:**
- MUST NEVER store secrets in Terraform files or state
- MUST avoid overly permissive IAM roles or network rules
- MUST NOT disable security features for convenience
- MUST NOT use default passwords or keys

**Operational:**
- MUST NOT apply Terraform changes directly to production without testing
- MUST avoid making manual changes to Terraform-managed resources
- MUST NOT ignore Terraform state file corruption or inconsistencies

## 3. Organize Code Cleanly

Each module under `modules/` follows a consistent structure:
- `main.tf` for resources
- `variables.tf` for inputs
- `outputs.tf` for outputs
- Use `locals.tf` when complex expressions are needed

Use `snake_case` for variables and module names.

## 4. Variable and Code Style Standards

- **Variable naming**: Use snake_case for all variable names
- **Variable definitions**: All variables must have explicit type declarations and descriptions
- **Sensitive variables**: Mark sensitive variables appropriately
- **Dynamic blocks**: Use dynamic blocks for optional nested objects where appropriate

## 5. Secrets

- Use Managed Identities rather than passwords or keys wherever possible
- Where secrets are required, store in Key Vault
- Never write secrets to local filesystems or commit to git
- Mark sensitive values appropriately in variables and outputs

## 6. Outputs

- Avoid unnecessary outputs; only expose information needed by other configurations
- Use `sensitive = true` for outputs containing secrets
- Provide clear descriptions for all outputs

## 7. Follow Recommended Terraform Practices

- **Dependencies**: Prefer implicit dependencies over explicit `depends_on`. Retain `depends_on` only where explicitly required. Never depend on module outputs.
- **Iteration**: Use `count` for 0-1 resources, `for_each` for multiple resources. Prefer maps for stable resource addresses.
- **Parameterization**: Use strongly typed variables with explicit `type` declarations and comprehensive descriptions.
- **Versioning**: Target latest stable Terraform and Azure provider versions.

## Azure-Specific Best Practices

### Resource Naming and Tagging

- Follow Azure Cloud Adoption Framework naming conventions
- Use consistent region naming variables for multi-region deployments (primary: swedencentral, secondary: germanywestcentral)
- Implement consistent tagging

### Networking Considerations

- Validate existing VNet/subnet IDs before creating new network resources
- Use NSGs appropriately
- Implement private endpoints for PaaS services when required
- Comment exceptions where public endpoints are required

### Security and Compliance

- Use Managed Identities instead of service principals
- Implement Key Vault with appropriate RBAC
- Enable diagnostic settings for audit trails
- Follow principle of least privilege

## State Management

- Use remote backend (Azure Storage) with state locking
- Never commit state files to source control
- Enable encryption at rest and in transit

## Validation

- Run `terraform validate` to check syntax
- Test configurations in non-production environments first
- Ensure idempotency (multiple applies produce same result)
