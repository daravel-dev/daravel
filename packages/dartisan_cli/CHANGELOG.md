# Changelog

## Unreleased

- Added `test:stress [--url] [--scenario] [--path] [--rounds] [--requests] [--concurrency] [--isolates] [--warmup] [--cooldown] [--max-p95] [--min-rps] [--json] [--export-public]`: load against a running application in rounds (health, ping, 404, an authenticated `me`, a rate-limited login, custom routes), with throughput mean ± stdev and p50/p95/p99, failing on a 5xx, a missing response, an unexpected status or a threshold; `--export-public` writes only allowed fields, never the target, tokens or custom routes.
- Added `e2e:install`, `make:e2e <Name> [--api]` and `test:e2e [--serve] [--url] [--api] [--ui] [-- playwright args]`: a Playwright end-to-end suite in `tests/e2e` (health, token authentication, the 422 body, login rate limiting, the welcome page and its headers), run against a fresh database or any URL.
- `pub:add` lists `daravel_pulse` (`pulse`), and `upgrade` updates it.

## 1.16.0

- Added `security:audit [--target] [--format=terminal|json|sarif] [--output] [--severity] [--only] [--json-path]`: a black-box audit of a running server for deployment mistakes (13 checks, single harmless requests), exiting 1 at `--severity` for CI.
- Changed: `coordinator:stats --url=<server>/metrics [--token] [--json]` reads the running server's coordinator (queue, refused calls, round trips by service with p50/p99) and says what to do; without `--url` it still shows the process's own coordinator.
- Added `build --docker --distroless`: the generated `Dockerfile` runs on `gcr.io/distroless/cc-debian12:nonroot`.
- `pub:add` lists `daravel_medialibrary` (`media`).

## 1.15.0

- Added `pub:list [--json]`, `pub:search <term> [--online]` and `pub:add <package...>` (alias `install`, `--yes`, `--no-get`): install a first-party package by name or alias, with its dependency, `.with*()` registration, migrations, commands and `.env.example` settings; the database and Redis packages delegate to `db:install` and `redis:install`. A typo stops with a suggestion; a package outside Daravel needs confirmation or `--yes`.

## 1.14.0

- Changed: `doctor --production` fails unless `APP_ENV=production` (the production-only checks were silently skipped under any other environment, so the gate passed on a configuration never deployed as such); `DoctorCommand.diagnose({production})`.
- Added production checks to `doctor`: a missing `APP_KEY` is an error; `HASH_VERIFY=false`, `BCRYPT_ROUNDS` below 10 and `HTTP_MAX_BODY=0` (no body limit) are warnings; a plain-`http` `APP_URL`, `HASH_DRIVER=pbkdf2` and secrets in a plain `.env` (no `.env.encrypted`) are notes. A missing `.env` is a note, not a warning, when `APP_ENV` comes from the OS environment, so the gate passes inside the image `build --docker` produces.
- Fixed: `migrate --seed` runs the root seeder; the flag was declared and never read.
- Changed: `migrate:rollback`, `migrate:reset`, `db:seed` and `migrate --seed` refuse to run under `APP_ENV=production` without `--force`, as artisan's do (`migrate:fresh` already did); plain `migrate` is unchanged.
- Changed: a framework error (configuration, a migration the registry does not know) is one `Error:` line on stderr and exit 1 instead of a stack trace and the VM's 255; `--verbose` or `DARAVEL_DEBUG=true` keeps the trace.
- `mcp:serve` also refuses `down` and `env:encrypt` under `APP_ENV=production`.

## 1.13.0

- Added `serve --max-in-flight` and `serve --max-queue-delay` (also passed on by `serve --watch`); new projects set `HTTP_MAX_QUEUE_DELAY=200ms`.
- Added `CheckStatus.notice`: `doctor` notes one isolate on a machine with more cores, `LOG_LEVEL` below `warning` and a SQLite file shared by several isolates, never failing, not even with `--production`. The PostgreSQL pool check counts the pool the driver opens and says "skipped" when the database is unreachable.
- `db:install pgsql` writes `DB_POOL_SIZE=10` and `HTTP_MAX_IN_FLIGHT=40` into the PostgreSQL block of `.env.example`.

## 1.12.0

- Version aligned with Daravel 1.12.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.11.0

- Version aligned with Daravel 1.11.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.10.1

- Version aligned with Daravel 1.10.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.10.0

- Version aligned with Daravel 1.10.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.9.0

- Added `dartisan upgrade [--check] [--to=<version>]` and `dartisan self-update`.
- Added `dartisan --version` (`-V`).
- Added `make:mail` and `make:notification`.
- `mcp:install` in a DDEV project registers `ddev dartisan mcp:serve` and adds `.ddev/commands/web/dartisan`.

## 1.8.1

- Fixed: `client:flutter --state` adapters (`providers.dart`, `blocs.dart`, `cubits.dart`) no longer fail `dart analyze --fatal-infos` with an unused import when no route uses a paginator or an upload.

## 1.8.0

- Added `db:install <driver>` and `db:transfer --from --to`.
- Added `client:flutter --state=riverpod,bloc,cubit` and `--watch`; a schema's `title` names its model and a 204 response is `void`.
- `dartisan new` projects declare their auth routes (`.validates()`, `.returns()`).

## 1.7.0

- Added `client:flutter`: generates a typed Dart/Flutter client package (`package:http`) from the routes, with models, paginators, error exceptions, SSE and WebSocket URLs, and the server's validation rules and messages checked on the device.

## 1.6.0

- Requires `daravel` 1.6.0 (server-sent events and WebSocket routes); the bundled guide includes the new section.

## 1.5.1

- Requires `daravel` 1.5.1 (JSON number range fix).

## 1.5.0

- `dartisan daragic:export [--out] [--only]`: the application model (DAM) in `dam.json` with `daragic.lock`.
- Requires `daravel` 1.5.0.

## 1.4.1

- Requires `daravel` 1.4.1 (response header fix).

## 1.4.0

- `dartisan db:backup [--output] [--keep=N]`: hot SQLite backups (`VACUUM INTO`, integrity checked).
- `dartisan new` includes the feature flags migration; the welcome page links to `/docs/api`.
- `buildOpenApi` is re-exported from `package:daravel`.
- Requires `daravel` 1.4.0.

## 1.3.0

- `dartisan model:show <Model> [--json]`; `make:model` adds models to `bootstrap/models.dart`, which `dartisan new` now creates.
- `mcp:serve` tools `models`, `db_query` (read-only), `read_logs`, `last_error`; `docs_search` with `locale: "id"`.
- `dartisan mcp:install` and `dartisan new --mcp` (`.mcp.json` + `AGENTS.md`).
- `schedule:list --timezone`; `doctor` warns when `APP_TIMEZONE` is not UTC and `SCHEDULE_TIMEZONE` is empty.
- `build --docker` leaves SQLite out when `DB_CONNECTION` is not `sqlite`.
- Requires `daravel` 1.3.0.

## 1.2.0

- `dartisan mcp:serve [--allow-write]`: MCP server on stdio for AI coding agents (`about`, `routes`, `schema`, `conventions`, `docs_search`; `run_command` opt-in).
- `dartisan build --no-sqlite`: bundle without the SQLite library for PostgreSQL/MySQL apps; `doctor` warns about `source: system` on an SQLite app.
- `schedule:list` shows each task's zone.
- Requires `daravel` 1.2.0.

## 1.1.0

- `dartisan lint` reports `unawaited_in_db_transaction` and `invalid_validation_rule`.
- Requires `daravel` 1.1.0.

## 1.0.0

- `down` and `up` (maintenance mode), `db:show`, `db:table` and `tinker`.
- MySQL and MariaDB: new projects register `daravel_mysql`, and `adopt` accepts MySQL applications.
- `openapi:generate` documents routes with file rules as `multipart/form-data`.

## 1.0.0-beta.3

- `openapi:generate` documents request bodies, query parameters and responses (Laravel resource and paginator envelopes, `components.schemas`) from route metadata.
- `queue:pause` and `queue:continue`; `queue:work` and `schedule:work` stop gracefully on `SIGTERM`.
- `doctor` compares the connection pool against the server's `max_connections`.
- `env:encrypt`, `env:decrypt` and `env:obfuscate`; `adopt <laravel-path> [--check]`; `serve --embed-queue --embed-scheduler`.

## 1.0.0-beta.2

- Inside a project, the global `dartisan` now runs the project CLI for every command, including `dartisan`, `dartisan --help` and `dartisan <command> --help`; only `new` stays global.
- `dartisan new` projects serve the Daravel welcome page at `/` (HTML, or JSON for API clients) and include a welcome test; instructions use `dartisan <command>`.
- The generated Dockerfile sets `PORT=8080` so container platforms can override it.

## 1.0.0-beta.1

First public beta: `dartisan new` (api and minimal templates with CI and conformance tests), dev server with hot reload, generators, migrations, queue and schedule commands, `doctor`, `test`, native `build` (bundle with SQLite) and `--docker`, `openapi:generate`, `model:sync`.

The full history of the Daravel workspace is in the
[repository changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).
