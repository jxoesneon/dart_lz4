# Governance (recommended settings)

This document summarizes recommended GitHub repository settings for `dart_lz4`.

## Branch protection (default branch)

Recommended rules for the default branch (e.g. `main`):

- Require pull request reviews before merging.
- Require review from Code Owners.
- Require status checks to pass before merging.
  - Suggested required checks: `CI / Format, Analyze, Test`.
- Require branches to be up to date before merging.
- Dismiss stale approvals when new commits are pushed.
- Restrict who can push to the protected branch.

## Tags and releases

- Protect release tags (e.g. pattern `v*.*.*`).
- Restrict who can create tags matching the release pattern.
- Prefer tag-driven releases only (see `.github/workflows/release.yml`).

## Security and supply-chain

Recommended GitHub security features:

- Enable Dependabot alerts.
- Enable Dependabot security updates.
- Enable secret scanning and push protection.
- Keep GitHub Actions pinned to specific SHAs.

## CI hygiene

- Keep CI required checks minimal and deterministic.
- Keep scheduled workflows non-blocking (benchmarks, scorecard).

## Permissions

- Prefer least-privilege workflow permissions.
- Avoid long-lived secrets; prefer GitHub OIDC where available.
