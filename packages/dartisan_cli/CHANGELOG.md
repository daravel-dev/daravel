# Changelog

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
