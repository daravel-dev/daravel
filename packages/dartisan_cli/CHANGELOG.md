# Changelog

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
