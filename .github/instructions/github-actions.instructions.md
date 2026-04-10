---
applyTo: '.github/workflows/*.yml,.github/workflows/*.yaml'
description: 'GitHub Actions CI/CD best practices for workflow files.'
---

# GitHub Actions CI/CD Best Practices

## Workflow Structure
- Use consistent, descriptive names for workflow files.
- Define `permissions` at the workflow level for a secure default.
- Use `concurrency` to prevent simultaneous runs for specific branches.

## Jobs
- Define `jobs` with clear `name` and appropriate `runs-on`.
- Use `needs` to define dependencies between jobs.
- Employ `outputs` to pass data between jobs efficiently.
- Use `if` conditions for conditional job execution.

## Steps and Actions
- Always pin actions to a full-length commit SHA for security. Tags are mutable and vulnerable to supply chain attacks.
- Add the version as a comment for readability (e.g., `# v4.3.1`).
- Use `name` for each step for readability in logs.
- Use `run` for shell commands, combining commands with `&&` for efficiency.
- Audit marketplace actions before use. Prefer actions from trusted sources.

## Security
- Always use GitHub Secrets for sensitive information.
- Use OIDC for cloud authentication (Azure, AWS, GCP) instead of long-lived credentials.
- Configure `permissions` to restrict `GITHUB_TOKEN` access. Default to `contents: read`.
- Integrate dependency scanning and SAST tools into the pipeline.
- Enable secret scanning for the repository.

## Optimization
- Use `actions/cache` for caching dependencies and build outputs.
- Design cache keys using `hashFiles` for optimal hit rates.
- Use `strategy.matrix` to parallelize tests across environments.
- Use `fetch-depth: 1` for `actions/checkout` when full history isn't needed.
- Set `timeout-minutes` for long-running jobs.

## Deployment
- Use GitHub `environment` rules with protections for staging/production.
- Implement manual approval steps for production deployments.
- Have clear rollback strategies.
- Run post-deployment health checks and smoke tests.
