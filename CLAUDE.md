# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Daravel is a Laravel 11/12-style backend framework for Dart that compiles to a single AOT native binary, plus the `dartisan` CLI and (designed, not yet built) `daragic`, a bidirectional Laravel ⇄ Daravel generator. The product goal is that Laravel and Daravel can run side by side on the same database and migrate in either direction, so **wire and storage formats are Laravel-compatible on purpose** (error/422 JSON, paginator and resource JSON, `personal_access_tokens`, `$2y$` bcrypt, `Crypt` payloads, `migrations`/`cache`/`jobs`/`failed_jobs` tables). Do not change these formats casually.

Design documents are binding. They are git-ignored and kept locally by the maintainer; a fresh clone does not have them:
- `BLUEPRINT_V2.md`: architecture, ADRs (ADR-016…023 in §16.10 override earlier ADRs), module specs, and the slice roadmap in §12 (Tier 1 = S1…S14). Work proceeds slice by slice.
- `BLUEPRINT_DARAGIC.md`: the generator (ADR-D01…D06).
- `docs/reviews/` (git-ignored, local only; may be absent in a fresh clone): weekly reviews with open action items (e.g. MySQL driver S5b/ADR-019, conformance suite, `RouteEntry` `.validates()/.returns()/.action()` metadata, queue payload isolation when sharing tables with Laravel). New reviews follow the naming and 5-section format in `docs/reviews/README.md`.

Blueprints and reviews are written in Bahasa Indonesia; code, identifiers, comments and commit messages are in English.

## Commands

Pub workspace (Dart SDK `^3.13`). The SDK is pinned in `.fvmrc` (Flutter 3.47.5 = Dart 3.13.4): run commands as `fvm dart …`, because a plain `dart` earlier on PATH may be older and is rejected by the `^3.13` constraint. The commands below write `dart` for brevity. Run `dart pub get` once at the repo root. Tests must be run **from inside each package directory**.

```bash
dart format --output=none --set-exit-if-changed .   # CI gate
dart analyze --fatal-infos                           # CI gate (whole workspace)

(cd packages/daravel && dart test)                   # framework (incl. test/architecture_test.dart)
(cd packages/daravel_lints && dart test)
(cd packages/daravel_test && dart test)
(cd packages/dartisan_cli && dart test)
(cd apps/daravel_starter && dart test)

# single file / single test
(cd packages/daravel && dart test test/database/orm_test.dart)
(cd packages/daravel && dart test test/database/orm_test.dart --name "soft delete lifecycle")

# gated suites
(cd packages/daravel && DARAVEL_TEST_PG=postgres://daravel:secret@127.0.0.1:5432/daravel_test \
  dart test test/database/postgres_integration_test.dart)
(cd packages/dartisan_cli && DARAVEL_E2E=1 dart test test/s12_test.dart --name e2e)  # dartisan new → pub get → analyze → test (~1 min)

# tagged suites (dart_test.yaml)
(cd packages/daravel && dart test --tags conformance)  # Laravel 12 wire/storage contracts
(cd packages/daravel && dart test --tags security)     # BLUEPRINT_V2 §9.3 suite

dart run tool/docs/generate.dart          # refresh docs/guide (parity.md, examples) + build/site
dart run tool/docs/generate.dart --check  # CI gate: docs/guide must be up to date
dart run tool/conformance/sync_laravel_messages.dart   # regenerate Laravel validation fixture
(cd bench && dart run bin/bench.dart --duration=5 --isolates=1,4)   # benchmark harness
```

Starter app (`apps/daravel_starter`), using its project-bound CLI:

```bash
dart run bin/dartisan.dart key:generate
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch          # hot reload; --isolates=N for supervisor mode
dart run bin/dartisan.dart lint                   # daravel_lints + registry check
dart build cli -t bin/server.dart -o build/server   # AOT bundle: bundle/bin/server + bundle/lib/sqlite3
dart run tool/smoke.dart                          # CI smoke test of build/server/bundle/bin/server(.exe)
```

`migrate:fresh` refuses to run when `APP_ENV=production`, which is the default without a `.env`; use `APP_ENV=local`. For throwaway runs, set `DB_DATABASE=":memory:"`.

Brand assets (`docs/brand/`: SVG source of truth, PNG sizes, `favicon.ico`, and the starter's embedded `logo_data.dart`) are generated from geometry in `tool/brand/generate.dart`: run `dart run tool/brand/generate.dart` from the repo root (needs Chrome/Edge; `--svg-only` without). Never hand-edit the outputs.

CI (`.github/workflows/ci.yml`) runs format, analyze, every package's tests, the AOT compile and the smoke test on Linux/Windows/macOS. The `dartisan new` e2e test runs on Linux only.

## Architecture

**Packages.** `packages/daravel` (core, one barrel `lib/daravel.dart`, modules under `lib/src/<module>`), `packages/dartisan_cli` (CLI, generators, `dartisan new` templates), `packages/daravel_test` (TestClient, `refreshDatabase`, assertions, time travel, architecture helpers), `packages/daravel_lints` (AST lint rules on `package:analyzer`, run as `dartisan lint`/tests, not an IDE plugin), `apps/daravel_starter` (reference app; its tests are the end-to-end spec), `bench` (benchmark harness, BLUEPRINT_V2 §10.2). User docs live in `docs/guide` (generated parts: `parity.md` and the code samples).

**Composition root.** `lib/src/foundation/application.dart` is the only file allowed to import every module. `Application.configure(...).with*(...).create()` builds an unbooted app; `boot()` loads env → typed config sections → `ConfigValidator` → container bindings → providers → routes → `router.compile` → `config.freeze()` → `Container.setRoot`. `Application.serveWith(createApp)` serves in-process when `isolates <= 1`, otherwise a `Supervisor` spawns N worker isolates that each call the (top-level, sendable) `createApp`.

**Module boundaries are enforced.** `packages/daravel/test/architecture_test.dart` holds an explicit `allowedDependencies` map between `lib/src` modules. A new cross-module import fails until it is deliberately added there. Keep `foundation` (except `application.dart`), `logging` and `storage` free of other modules.

**Container + Zones.** `Container.runScoped('request'|'job'|'command', …)` stores a `Scope` in a child `Zone`; facades (`DB`, `Auth`, `Cache`, `Queue`, `Event`, `Log`, `Storage`, `Hash`, `Crypt`, `Gate`, `Schema`, `Config`) resolve `Container.current` (zone first, then the per-isolate root), so they work in requests, jobs, CLI and tests. Per-request state lives in the scope: the `Request`, `AuthState` (resolved users, active guard, current token), `LogContext` (`request_id`, `Log.withContext`). Both `ServerEngine` and `Application.handle` must put the `Request` into the scope — the test client path and the socket path must stay equivalent.

**Transactions are zone-based.** `DB.transaction` puts the executor in the zone, and nested calls become savepoints. `DatabaseManager.afterCommit` queues callbacks that run on the outer commit and are dropped on rollback. Queue dispatch and `Event.dispatchAfterCommit` use this by default. `rollbackAfter` (used by `refreshDatabase`) is a baseline transaction whose app-level savepoints still fire their after-commit callbacks.

**State scopes (ADR-003).** Stores declare `isolate`, `process` or `cluster` scope. Process-wide state (rate limits, `process` cache store, locks, merged Prometheus metrics) is served by a `Coordinator` over `SendPort`, either `LocalCoordinatorChannel` (single isolate) or `RemoteCoordinatorChannel` (supervisor mode). Rate limiting fails open; locks fail closed.

**No reflection, no build_runner (ADR-002).** Everything discovered automatically in Laravel is an explicit Dart list or registration function in `bootstrap/`: `migrations.dart`, `seeders.dart`, `jobs.dart` (`JobDefinition(name, fromJson)`), `policies.dart` (`registerPolicies(gate)`), `listeners.dart` (`registerListeners(events)`), `commands.dart` (`List<CommandFactory>`). Generators patch these through `// <dartisan:imports>` / `// <dartisan:entries>` regions (`RegistryPatcher`). `registry_entry_missing` and `expectRegistryComplete()` catch files left out of a registry.

**Models (Hybrid Active Record, ADR-006 revised).** Pattern for every model:
```dart
final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(table: 'users', factory: User.new, relations: {'posts': () => HasMany<Post>(() => Post.definition, foreignKey: 'user_id')});
  @override
  ModelDefinition<User> get modelDefinition => User.definition;
  // <dartisan:statics> … // </dartisan:statics>   (query/find/create helpers)
  // <dartisan:accessors> … // </dartisan:accessors> (typed getters/setters; rewritten by `dartisan model:sync`)
}
```
The static is `definition` and the instance getter is `modelDefinition`, because Dart forbids a static and an instance member with the same name. Keep the explicit `ModelDefinition<User>` type, since inferred mutually referencing statics create inference cycles. Relations are thunks for the same reason.

**Time.** Domain time (model timestamps, token/JWT expiry, cache TTL, rate-limit windows, delayed jobs, schedules, signed URLs) must use `Clock.now()` (`foundation/clock.dart`), so tests can `freezeTime()`/`travel()`. Wall-clock concerns (polling deadlines, timeouts, worker `--max-time`, log timestamps, request ids) keep `DateTime.now()`. A frozen clock in a polling loop never advances.

**Generators and templates.** All `make:*` output comes from `{{ var }}` templates in `packages/dartisan_cli/lib/src/stubs.dart`; projects can override them in `stubs/<name>.stub` (`stub:publish`). `dartisan new` templates live in `new_project.dart` and should mirror the starter. The generated pubspec needs `dependency_overrides` for `daravel`, `daravel_lints` and `daravel_test`, because `dartisan_cli`/`daravel_test` depend on them by name. The e2e test is the guard: it generates a project and runs `dart analyze --fatal-infos` and `dart test` on it.

## Conventions and gotchas

- **Laravel-facing formats are locked by the conformance suite.** Fixtures and matchers live in `packages/daravel_test/lib/src/conformance/` (`LaravelContract`, citing the Laravel/Sanctum source); tests in `packages/daravel/test/conformance/`. Changing an error body, paginator/resource JSON, token, hash, `Crypt` payload, date format or shared-table schema means updating the contract deliberately (and an ADR). Verify against the real Laravel 12.x source, not memory.
- `parity.yaml` (repo root) maps Laravel APIs to Daravel symbols; `test/parity_test.dart` fails if a `symbol` disappears. Guide snippets come from `packages/daravel/test/docs/guide_examples_test.dart` regions; after editing that file or `parity.yaml`, run `dart run tool/docs/generate.dart`.
- Binding defaults from ADR-008 stay: Crypt AES-256-GCM and Argon2id. Laravel coexistence is opt-in via `APP_CIPHER=AES-256-CBC` and `HASH_DRIVER=bcrypt`.
- The release number lives in `daravelVersion` (`foundation/version.dart`); `test/foundation/version_test.dart` keeps every workspace pubspec equal to it.
- Strict analysis is non-negotiable: `strict-casts`, `strict-inference`, `strict-raw-types`, plus `unawaited_futures`, `avoid_dynamic_calls`, `close_sinks` and others (`analysis_options.yaml`). Closures passed where the parameter type is `Object` need explicit parameter types, e.g. `where((QueryBuilder q) { … })` or `(Faker f) => {…}`.
- Names already taken or reserved in Dart: `with` (resource extra data is `withMeta`), `Factory` (container typedef, so model factories are `ModelFactory<T>`), `CommandRunner` (`package:args`, so scheduler commands use `ScheduleCommandRunner`), `ScheduledTask.name` is a getter (`named()` sets it), `Rules` is the rule facade because `Rule` is the base class.
- SQLite quirks the code already handles: no parenthesized UNION members (`wrapUnion`); column alters go through `SqliteTableRebuilder` (backup table + `defer_foreign_keys` inside a savepoint); in-memory databases cannot be shared across isolates, so `serve` refuses `:memory:` with `isolates > 1`.
- `daravel_lints` rules target application code. `no_sql_string_interpolation` skips `lib/src/`, where SQL is built from grammar-quoted identifiers with bound values. Suppress a finding with `// daravel-lint-ignore: <rule>`.
- Known gaps by design: MySQL runtime driver (grammars exist, the driver throws), morph relations, Blade compiler, multipart uploads/`UploadedFile`, S3, sessions/CSRF, Redis, mail, and IDE-integrated lints. These are Tier 2 or pending slices.
- Commit only when explicitly asked. Each slice is committed as `Tier 1 / S<n>: <summary>`.
