---
applyTo: '**/*.tf'
description: 'General Terraform conventions and guidelines.'
---

# Terraform Conventions

## General Instructions

- Use Terraform to provision and manage infrastructure.
- Use version control for all Terraform configurations.

## Security

- Always use the latest stable version of Terraform and its providers.
- Never commit sensitive information such as credentials, API keys, passwords, or Terraform state to version control.
- Always mark sensitive variables as `sensitive = true`.
- Use IAM roles and policies following the principle of least privilege.
- Use encryption for sensitive data at rest and in transit.

## Modularity

- Use separate modules for each major component of the infrastructure.
- Use modules to encapsulate related resources and configurations.
- Avoid circular dependencies between modules.
- Avoid unnecessary layers of abstraction; use modules only when they add value.
- Use `output` blocks to expose important information about your infrastructure.
- Avoid exposing sensitive information in outputs; mark outputs as `sensitive = true`.

## Maintainability

- Prioritize readability, clarity, and maintainability.
- Use comments to explain complex configurations and design decisions.
- Avoid using hard-coded values; use variables for configuration instead.
- Use data sources to retrieve information about existing resources.
- Use `locals` for values that are used multiple times.

## Style and Formatting

- Use descriptive names for resources, variables, and outputs.
- Use consistent naming conventions across all configurations.
- Use consistent indentation (2 spaces for each level).
- Group related resources together in the same file.
- Place `depends_on` blocks at the beginning of resource definitions.
- Place `for_each` and `count` blocks at the beginning of resource definitions.
- Place `lifecycle` blocks at the end of resource definitions.
- Use `terraform fmt` to format configurations automatically.
- Use `terraform validate` to check for syntax errors.

## Documentation

- Always include `description` and `type` attributes for variables and outputs.
- Document configurations using comments where appropriate.
- Include a `README.md` file in each module to provide an overview.

## Testing

- Write tests to validate Terraform configurations.
- Use the `.tftest.hcl` extension for test files.
- Write tests to cover both positive and negative scenarios.
- Ensure tests are idempotent.
