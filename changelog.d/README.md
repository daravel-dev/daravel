# Changelog fragments

Each pull request writes its notes in a file of its own here,
`changelog.d/<slug>.md`, instead of in `## Unreleased` of
[CHANGELOG.md](../CHANGELOG.md), so two pull requests never touch the same
lines and the merge queue can take them one after the other (Blueprint
#142, ADR-038).

- **Name:** lower case letters, digits and dashes (`^[a-z0-9][a-z0-9-]*$`),
  ending in `.md`. Use the branch name: `horizon-package.md`.
- **Content:** only these headers, each optional, each with at least one
  `- ` note under it, and nothing else (blank lines aside):

```markdown
### Added

- What is new, in the style of CHANGELOG.md: one long line per change,
  naming the issue or pull request.

### Changed

- What behaves differently.

### Upgrade notes

- What an upgrade can change for an application: a new public name in a
  package's library, a changed default. Required when the change adds an
  `export` to `packages/<pkg>/lib/*.dart`.

### Fixed

- What was wrong.
```

`dart run tool/changelog.dart --preview` prints `## Unreleased` as the next
release will write it: the notes still in CHANGELOG.md first, then every
fragment by file name, section by section (upgrade notes under
"**Upgrading can change what an application sees:**"). `tool/release.dart`
writes that into the version's section and removes the fragments in the
release commit. `dart run tool/changelog_check.dart` validates the
fragments in CI. This file is not a fragment.
