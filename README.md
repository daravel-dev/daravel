# Daravel

Laravel-inspired, AOT-native backend framework for Dart, with the `dartisan` CLI and the
`daragic` Laravel ⇄ Daravel generator (see `BLUEPRINT_V2.md` and `BLUEPRINT_DARAGIC.md`).

**Status:** Tier 0 walking skeleton (BLUEPRINT_V2 §12) — container + zone scopes, application
builder, HTTP kernel, radix router, SQLite access, schema migrations, `TestClient`, CLI, CI.

## Workspace

```text
packages/daravel         framework core        (package:daravel/daravel.dart)
packages/daravel_test    testing toolkit       (TestClient, assertions)
packages/dartisan_cli    dartisan CLI          (serve, route:list, migrate*)
apps/daravel_starter     reference application (Laravel 12 layout)
```

## Quick start

```bash
dart pub get                                   # resolves the whole workspace
cd apps/daravel_starter
cp .env.example .env
dart run bin/dartisan.dart migrate             # creates database/database.sqlite
dart run bin/dartisan.dart serve               # http://127.0.0.1:8000/up, /api/ping
dart test                                      # feature tests (in-memory SQLite)
```

Native binary:

```bash
dart compile exe bin/server.dart -o build/server      # build/server.exe on Windows
dart run tool/smoke.dart build/server                 # boots the binary and probes /up, /api/ping
```

On Linux the SQLite shared library must be present (`apt-get install libsqlite3-0`); on Windows
the driver falls back to the system `winsqlite3.dll` when `sqlite3.dll` is not on the PATH.

## Quality gates

`dart format --set-exit-if-changed .` · `dart analyze --fatal-infos` (strict casts/inference/raw
types) · `dart test` per package · AOT compile + smoke test on Linux, Windows and macOS
(`.github/workflows/ci.yml`).
