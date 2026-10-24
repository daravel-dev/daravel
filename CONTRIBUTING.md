# Contributing to Daravel

Thanks for helping. Design discussion is as welcome as code: open an issue
to propose a change of behaviour or API before sending a large pull request.

## Workspace

Daravel is a Dart pub workspace (SDK `^3.13`, pinned for maintainers in
`.fvmrc`; use `fvm dart …` when the `dart` on your `PATH` is older).

| Path | Package |
| :-- | :-- |
| `packages/daravel` | the framework (`lib/src/<module>`, one barrel `lib/daravel.dart`) |
| `packages/daravel_test` | testing toolkit and the Laravel conformance contracts |
| `packages/daravel_lints` | AST lint rules (`dartisan lint`) |
| `packages/dartisan_cli` | the CLI, generators and `dartisan new` templates |
| `apps/daravel_starter` | reference application; its tests are the end-to-end spec |
| `bench` | benchmark harness |
| `docs/guide` | user documentation (parts generated, see below) |

```bash
dart pub get                                         # once, at the repository root
```

## Before you push

Every pull request must keep these green (CI runs them on Linux, Windows and
macOS):

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart run tool/docs/generate.dart --check
(cd packages/daravel && dart test)        # includes conformance, security, parity, architecture
(cd packages/daravel_lints && dart test)
(cd packages/daravel_test && dart test)
(cd packages/dartisan_cli && dart test)
(cd apps/daravel_starter && dart test && dart run bin/dartisan.dart lint)
```

Run tests from inside each package directory. `DARAVEL_E2E=1` enables the
`dartisan new` end-to-end test in `packages/dartisan_cli`.

## Rules of the codebase

- **Strict analysis** (`strict-casts`, `strict-inference`, `strict-raw-types`
  and the lints in `analysis_options.yaml`) with no ignores.
- **No reflection and no build-time code generation**: everything Laravel
  discovers automatically is an explicit registration (`bootstrap/*.dart`).
- **Module boundaries** in `packages/daravel/lib/src` are enforced by
  `test/architecture_test.dart`; a new cross-module import needs a deliberate
  entry there.
- **Laravel-facing formats are contracts.** Error bodies, pagination and
  resource JSON, tokens, hashes, `Crypt` payloads, dates and shared table
  schemas are locked by `packages/daravel/test/conformance`. Changing one
  requires updating `LaravelContract` (with the Laravel source it comes from)
  and a design decision (ADR).
- **Public API changes** update `parity.yaml` when a Laravel equivalent
  exists (`test/parity_test.dart` checks every symbol) and the guide in
  `docs/guide`. Code samples in the guide come from
  `packages/daravel/test/docs/guide_examples_test.dart` regions: edit the
  test, then run `dart run tool/docs/generate.dart`.
- **Domain time** reads `Clock.now()` so tests can freeze it.
- **Security fixes** get a regression test in
  `packages/daravel/test/security`; report vulnerabilities privately as
  described in [SECURITY.md](SECURITY.md).
- Every public API has a doc comment and a test.

## Commits

- Write commit messages in English, imperative mood, explaining why.
- Sign off every commit (Developer Certificate of Origin):
  `git commit -s` adds `Signed-off-by: Your Name <you@example.com>`.
- Add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) for
  user-visible changes.

By contributing you agree that your contributions are licensed under the
[MIT license](LICENSE).
