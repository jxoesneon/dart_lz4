# Contributing

Thanks for your interest in contributing.

## Ground rules

- By participating, you agree to follow the Code of Conduct.
- Keep changes focused and incremental.
- Do not include secrets in commits.

## Development workflow

- Run `dart format --set-exit-if-changed .`
- Run `dart analyze`
- Run `dart test`

## Pull requests

- **Review Required:** All pull requests must be reviewed and approved by at least one maintainer before merging.
- **CI Gating:** All status checks (Format, Analyze, Test, Benchmark) must pass before a merge is permitted.
- **Incremental Changes:** Prefer one file per commit when practical.
- **No Direct Pushes:** Direct pushes to the `main` branch are prohibited by repository policy (enforced via branch protection).

## Reporting bugs

Open a GitHub issue with:

- Reproduction steps
- Expected vs actual behavior
- Dart SDK version
- Platform (VM/Flutter/Web)
