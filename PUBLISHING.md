# Publishing (maintainers)

This repository publishes the Dart package `dart_lz4` to pub.dev.

Repository:

- <https://github.com/jxoesneon/dart_lz4>

## Current release model

- Versioning: `pubspec.yaml` `version:`
- Tagging: `vX.Y.Z` (for example `v0.0.2`)
- Automation: `.github/workflows/release.yml`

The release workflow validates that:

- The pushed tag `vX.Y.Z` matches `pubspec.yaml` version `X.Y.Z`.
- `dart format`, `dart analyze`, and `dart test` pass.
- `dart pub publish --dry-run` passes.

## First publish

The first publish must be done manually.

```bash
dart pub publish
```

## Publisher / ownership (recommended)

To reduce single-maintainer risk, publish under a **pub.dev publisher** (organization) instead of an individual account.

1. Create (and verify) a pub.dev publisher for your organization/domain.
   - Start at: <https://pub.dev/publishers>
   - Follow pub.dev instructions to verify domain ownership (DNS TXT record).
2. Transfer the package to the publisher:
   - Go to: <https://pub.dev/packages/dart_lz4/admin>
   - Transfer package ownership to the publisher.
3. Add at least two publisher admins/owners (bus factor).
4. Use strong account security for the Google accounts used on pub.dev (2FA, recovery options).

## Access continuity

Recommended practices to ensure releases can continue even if an individual is unavailable:

- Ensure the package is owned by a publisher with multiple admins.
- Ensure GitHub org/repo access is not single-person (at least two admins).
- Keep GitHub Actions publishing gated (this repo uses `vars.PUB_PUBLISH`) and prefer an environment approval gate for actual publishing.

## Enable automated publishing from GitHub Actions (OIDC)

1. Go to:

- <https://pub.dev/packages/dart_lz4/admin>

1. In the **Automated publishing** section:

- Enable **Publishing from GitHub Actions**
- Repository: `jxoesneon/dart_lz4`
- Tag pattern: `v{{version}}`

Notes:

- pub.dev only accepts automated publishing when the workflow is triggered by pushing a tag.

## Enable publishing in CI

The release workflow is intentionally gated by a repository variable.

After automated publishing is enabled on pub.dev, set the GitHub repository variable:

- `PUB_PUBLISH=true`

GitHub UI path:

- Repository Settings
- Secrets and variables
- Actions
- Variables

Once set, pushes of tags like `v0.0.2` will publish `dart_lz4` version `0.0.2`.

## Optional hardening (recommended)

To prevent any user with tag-push access from publishing, you can use a GitHub Actions
**environment** gate:

- Create a GitHub Environment named `pub.dev` with required reviewers.
- Then update the release workflow job to use `environment: pub.dev`.

This is compatible with pub.dev automated publishing (the environment name is reflected
in the OIDC token used for authentication).
