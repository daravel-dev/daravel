## What and why

<!-- What does this change, and which issue does it address? -->

## Checklist

- [ ] `dart format --output=none --set-exit-if-changed .` and `dart analyze --fatal-infos` pass
- [ ] Tests added or updated, and every package's `dart test` passes
- [ ] A line in the `Unreleased` section of CHANGELOG.md for user-visible changes
- [ ] Laravel-facing formats (errors, pagination, tokens, `Crypt`, shared tables) unchanged, or the conformance contract updated on purpose
- [ ] Docs updated (`docs/guide`, then `dart run tool/docs/generate.dart`)
- [ ] Commits signed off (`git commit -s`), see CONTRIBUTING.md
