---
applyTo: '**/*.ps1'
description: 'PowerShell scripting best practices for DR runbooks and automation scripts.'
---

# PowerShell Best Practices

## General
- Use approved verbs from `Get-Verb` for function names.
- Use PascalCase for function names and parameters.
- Use `$camelCase` for local variables.
- Include `[CmdletBinding()]` on all advanced functions.
- Prefer full cmdlet names over aliases in scripts.
- Use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` for safety.

## Error Handling
- Use `try/catch/finally` for error-prone operations.
- Prefer terminating errors (`-ErrorAction Stop`).
- Use `Write-Error` or `throw` for error reporting, not `Write-Host`.
- Log errors with context (timestamp, function name, parameters).

## Output
- Use `Write-Verbose` for diagnostic output.
- Use `Write-Warning` for non-critical issues.
- Use `Write-Output` only for pipeline data.
- Return structured objects, not formatted strings.

## Parameters
- Use `[Parameter()]` attribute with `Mandatory`, `Position`, `HelpMessage`.
- Use `[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, `[ValidateRange()]` where appropriate.
- Provide sensible default values where possible.

## Azure-Specific
- Use `Connect-AzAccount` with managed identity or service principal in automation.
- Check Azure context with `Get-AzContext` before operations.
- Use `-WhatIf` and `-Confirm` support on destructive operations.
- Handle Azure throttling with retries and backoff.

## Security
- Never hardcode credentials in scripts.
- Use `SecureString` for passwords.
- Access secrets via Key Vault (`Get-AzKeyVaultSecret`).
- Avoid `Invoke-Expression` and string-based command construction.
