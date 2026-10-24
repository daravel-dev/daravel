# Changelog

All notable changes to the Daravel workspace (`daravel`, `daravel_test`,
`daravel_lints`, `dartisan_cli`). Versions follow SemVer; until 1.0.0 the
beta releases may still change Laravel-facing formats when the conformance
suite shows they differ from Laravel.

## Unreleased

### Added

- MySQL and MariaDB (ADR-019): the new `daravel_mysql` package (`MySqlDriver`, on
  the pure Dart `mysql_dart` client) and `ApplicationBuilder.withDatabaseDriver`.
  New projects and the starter register it, so `DB_CONNECTION=mysql` or
  `mariadb` works as in Laravel. Results read as Laravel reads them
  (`TINYINT(1)` as 0/1, `DECIMAL`/`JSON` as strings, dates as `Y-m-d H:i:s`),
  deadlocks are retried, and `dartisan adopt` accepts MySQL applications.
  CI runs MySQL 8.4 and MariaDB 11 on every commit.
- Issue forms and a pull request template.
- `Http`: outgoing requests with Laravel's `Http::` API (`withToken`, `baseUrl`,
  `timeout`, `retry`, `asForm`, JSON helpers on the response, `throwIfFailed`)
  and `Http.fake()` with patterns, sequences, `assertSent` and
  `preventStrayRequests`.
- Maintenance mode: `dartisan down [--secret] [--with-secret] [--retry]
  [--refresh] [--status] [--except]` and `up`, with Laravel's
  `storage/framework/down` file; `PreventRequestsDuringMaintenance` runs on
  every application (health routes stay up, signed bypass cookie).
- `dartisan db:show`, `db:table <table> [--limit]` and
  `tinker "<expression>"`.
- Documentation site: a landing page (EN/ID) with Laravel ⇄ Daravel examples,
  versioned docs under `docs/<version>/` (`docs/versions.yaml`, built from each
  branch by the Docs workflow), a categorised sidebar
  (`docs/guide/navigation.yaml`), "on this page" links, `Ctrl+K` search,
  light/dark themes, copy buttons and Indonesian pages with an English
  fallback. Old page URLs redirect.
- Guide pages: Releases, Configuration, Architecture, ORM and dartisan.

### Fixed

- `mediumText` and `longText` columns were plain `TEXT`; on MySQL they are now
  `MEDIUMTEXT`/`LONGTEXT`, as Laravel creates them (cache values, job payloads
  and failed job exceptions over 64 KB).
- Unique columns get a named index (`{table}_{column}_unique`), as Laravel
  names them, instead of an inline `UNIQUE` constraint.
- The migrator and the `unique` / `exists` rules quoted identifiers with double
  quotes, which MySQL rejects; they now use the query builder.
- MySQL `getColumns` read `extra` in MariaDB's lower case only; MySQL 8 returns
  it in upper case. Columns also report their primary key.
- SQLite: worker isolates (or processes) opening the same new database file
  at once could fail with "database is locked": switching to WAL answers
  `SQLITE_BUSY` without waiting for the busy timeout. The switch is now
  skipped when the file is already in WAL and retried briefly otherwise, and
  the busy timeout is set first.

## 1.0.0-beta.3

### Added

- `dartisan env:encrypt` / `env:decrypt` (the `.env.encrypted` format of
  `php artisan env:encrypt`, default and `--readable`, verified against
  Laravel 12.70.1 in both directions) and in-memory decryption at boot with
  `DARAVEL_ENV_ENCRYPTION_KEY` or `LARAVEL_ENV_ENCRYPTION_KEY`;
  `EnvironmentEncrypter`; `dartisan env:obfuscate` (XOR-masked Dart class).
- `dartisan adopt <laravel-path> [--check]`: copies the shared settings from a
  Laravel `.env` and checks version, driver, key, hashing and shared tables.
- `serve --embed-queue --embed-scheduler` (`SERVER_EMBED_QUEUE`,
  `SERVER_EMBED_SCHEDULER`): queue worker and scheduler in their own isolates
  next to the HTTP server; `EmbeddedWorkers`.
- `apps/daravel_starter/Dockerfile` (built from the repository root).
- `.env` values in double quotes may span several lines, as in phpdotenv.
- Declared route metadata: `RouteEntry.validates(FormRequest)` and `.rules({...})`
  validate before the handler (403/422) and feed `request.validated()`;
  `.returns(schema, name:, shape:)` and `.action(...)` describe responses.
  `dartisan openapi:generate` now emits request bodies, query parameters,
  Laravel resource/paginator envelopes and `components.schemas`;
  `rulesToJsonSchema` converts validation rules to JSON Schema.
- Extension points for monitoring tools (Horizon- and Telescope-style):
  `Job.tags` stored in the payload, `QueueDriver.oldestWait(queue)`,
  `QueueManager.pause` / `resume` with `dartisan queue:pause` /
  `queue:continue` (`[connection:]queue`, like Laravel 11), `QueueWorker.pause`
  / `resume`, and `DB.listen` with `QueryExecuted` events.
- PostgreSQL over a Unix socket: a `DB_HOST` path (`/cloudsql/project:region:db`)
  connects to `<dir>/.s.PGSQL.<port>`, as in Laravel and libpq.
- Guides: [Migrating from Laravel](docs/guide/migrating-from-laravel.md)
  (Strangler Fig behind Caddy or nginx) and Cloud Run and VPS (systemd +
  Caddy) sections in [Deployment](docs/guide/deployment.md).
- `Request.integer`, `float`, `boolean` and `string` (Laravel 12 parity), and
  `Request.queryInput` / `parseQueryString`, which read `ids[]=1&ids[]=2` and
  `filter[status]=x` like PHP's `parse_str`.
- A PostgreSQL CI job runs the integration suite (`--tags integration`).

### Changed

- `.env` parsing follows phpdotenv 5 (Laravel): only `${NAME}` is expanded;
  a bare `$NAME` stays literal and unknown references are kept as written
  (before, `$NAME` was expanded and unknown names became empty). Values
  such as passwords containing `$` now read the same in both frameworks.
- `QueueDriver` gained `oldestWait`; custom drivers must implement it.
- Form bodies are parsed into nested maps and lists (`Map<String, Object?>`)
  rather than `Map<String, String>`.

### Fixed

- Request timeouts no longer create a timer per request (one sweeper per
  kernel for timeouts of 2 s and more): `GET /ping` went from about 64% to
  79% of plain `dart:io` throughput on Linux. Request ids use three random
  draws instead of twelve, and requests skip empty awaits for route bindings
  and undeclared validation.
- `Scheduler.stop()` takes effect immediately instead of after the current
  minute.
- SQLite: queries from outside an open transaction (another request on the
  same isolate) ran inside it and were rolled back with it. They now wait
  until it commits or rolls back. Row counts and insert ids come from the
  connection instead of extra `SELECT changes()` / `last_insert_rowid()`.
- `request.input<int>('page')` returned the fallback for `?page=5`: query
  and form strings are now converted to `int`, `double`, `num` and `bool`.
- Query strings and form bodies keep bracketed keys as lists and maps
  (`ids[]=1&ids[]=2`) instead of dropping values, so `ids.*` rules apply.
- The access log measures the time to the response, without `terminate()`
  and `request.defer()` work; terminable global middleware run in priority
  order.
- `dartisan doctor` compares the pool size against the server's
  `max_connections` instead of assuming 100.
- `queue:work` and `schedule:work` stop gracefully on `SIGTERM` (systemd,
  Docker, Cloud Run), not only on `SIGINT`.

## 1.0.0-beta.2

### Added

- `dartisan new` projects open on the Daravel welcome page (HTML for browsers,
  JSON for API clients) with their own `welcome_test.dart`; the page is shared
  with the starter and the logo ships as `daravelLogoDataUri` /
  `daravelFaviconDataUri` in `package:daravel`.
- `PORT` fallback: without `APP_PORT`, the server uses the platform's `PORT`
  (Cloud Run, Railway, Render, Fly.io) and binds `0.0.0.0`; the Dockerfile
  sets `PORT=8080`.

### Changed

- The global `dartisan` delegates everything inside a project to its
  `bin/dartisan.dart`, including `dartisan`, `dartisan --help` and
  `dartisan <command> --help`; only `new` stays global. Generated READMEs and
  the post-create message use `dartisan <command>`.

### Fixed

- Sharing the `jobs` table with Laravel: a Daravel worker that met a Laravel
  job failed it into `failed_jobs` (or crashed on Laravel's string `backoff`).
  Laravel jobs are now skipped untouched and logged once, and `backoff` in
  Laravel's comma-separated form is accepted.

## 1.0.0-beta.1 (first pub.dev release; Tier 1 complete)

### Added

- pub.dev readiness: package metadata (homepage, repository, issue tracker,
  documentation, topics, platforms), explicit `^1.0.0-beta.1` constraints
  between packages, per-package `README`, `CHANGELOG`, `LICENSE`,
  `example/main.dart` and `.pubignore`; CI runs `dart pub publish --dry-run`
  and `.github/workflows/publish.yml` publishes on `v*` tags with GitHub OIDC.
- `dartisan new --source=pub|git` (pub.dev by default, a plain pubspec without
  `dependency_overrides`).
- Support layer (BLUEPRINT_V2 §7.12): `Str` (case conversion, slug, slicing,
  predicates, secure random, UUID/ULID, English plural/singular), global
  helpers (`abortIf`, `abortUnless`, `retry`, `rescue`, `once`, `blank`,
  `filled`, `tap`, `value`, `dataGet`, `now`, `today`) and Laravel-style
  `Iterable` extensions (`pluck`, `keyBy`, `groupBy`, `chunk`, `unique`,
  `sumBy`, `avgBy`, `sortBy`, `sortByDesc`, `partition`); guide page
  `docs/guide/helpers.md` and `parity.yaml` entries.
- Conformance vectors from independent implementations: argon2id PHC strings
  (libargon2 via argon2-cffi, and Bun), `$2b$` bcrypt, an AES-256-GCM Laravel
  payload (BoringSSL); `201 Created` for resources of just-created models.
- `CONTRIBUTING.md`, trademark disclaimer and generated-code ownership in the
  README, fair-use rules in `docs/brand/README.md`, and a "Where Dart differs
  from PHP by design" table in the coexistence guide.

### Changed

- The repository moves to `github.com/daravel-dev/daravel` (URLs in docs,
  templates and metadata).

### Removed

- `CLAUDE.md` is no longer tracked (kept locally, like the blueprints).

### Changed (ADR-024: zero-config Laravel coexistence)

- `Crypt` defaults to AES-256-CBC (encrypt-then-HMAC-SHA256) and hashing to
  bcrypt with cost 12, Laravel's defaults; `APP_CIPHER=AES-256-GCM` and
  `HASH_DRIVER=argon2id` remain available. **Upgrade:** apps that relied on
  the old defaults should set them explicitly; existing argon2id hashes keep
  verifying and are rehashed to bcrypt at login.
- `HASH_VERIFY` now accepts hashes of the strong family (bcrypt, argon2id)
  across a driver switch, so `rehashPasswordIfRequired` can upgrade them;
  weaker foreign formats (pbkdf2) are still refused.

### Performance

- The rate limiter uses Laravel's fixed-window counter (hits + reset time,
  O(1) per key) instead of a sliding-window log that copied every timestamp
  on each request. Windows now start with the first hit, as in Laravel.
- The coordinator answers synchronous services inline (no Future per
  message) and the remote channel enforces timeouts with one sweep timer
  instead of a timer per call.
- With several isolates, generous limits (≥ 32) are served from adaptive
  local leases with unused hits released, and blocked keys are answered
  locally for up to 100 ms. On the benchmark (Windows, indicative) the
  throttled route went from 45% to 96% of the unthrottled throughput on one
  isolate and from 2.2k to 9.5k req/s on four.

### Added (Tier 1 / S14)

- **Conformance suite** (`packages/daravel/test/conformance`, tag
  `conformance`): error bodies (401/403/404/405/413/422/429/500), validation
  semantics and all default English messages (generated from Laravel 12's
  `lang/en/validation.php` by `tool/conformance/sync_laravel_messages.dart`),
  paginator, simple and cursor paginator JSON, resource wrapping, JSON dates,
  `apiResource` routes, Sanctum tokens, bcrypt, `Crypt` payloads (checked
  against an OpenSSL-built Laravel payload) and the schema of every table
  shared with Laravel.
- `package:daravel_test/conformance.dart`: `LaravelContract` fixtures and
  matchers (`isLaravelValidationError`, `isLaravelErrorBody`,
  `isLaravelLengthAwarePaginator`, `isLaravelPaginatedResource`) for
  application tests; new projects ship `test/conformance/`.
- **Security suite** (`packages/daravel/test/security`, tag `security`) for
  BLUEPRINT_V2 §9.3, and `SECURITY.md`.
- **`parity.yaml`** (ADR-016): the Laravel ⇄ Daravel symbol map, verified
  against the source by `test/parity_test.dart`.
- **Documentation site**: `docs/guide` (English, with Indonesian core pages),
  built by `tool/docs/generate.dart`, which also renders the parity table
  and inlines code samples from compiled tests; CI fails when the docs are
  stale; `.github/workflows/docs.yml` publishes to GitHub Pages when enabled.
- **Benchmark harness** (`bench/`, BLUEPRINT_V2 §10.2) with a plain
  `dart:io` reference and a nightly workflow gating > 10% regressions.
- `dartisan test [--conformance] [--security] [--coverage]`.
- Templates: `dart_test.yaml` and a CI workflow in both templates;
  `test/conformance` and `docker-compose.yml` (PostgreSQL 16) in `api`;
  `register` is throttled and runs in a transaction.
- `APP_CIPHER` (`AES-256-GCM` default, `AES-256-CBC` for Laravel's default),
  `SANCTUM_TOKEN_PREFIX`, `ModelDefinition.morphClass`, `Request.url`,
  `paginate()` page/path resolution from the current request,
  `withQueryString()` / `appends()`, `crc32b()`, `daravelVersion`.

### Changed (formats now identical to Laravel)

- Pagination: absolute URLs from the request, Laravel's `UrlWindow`, a `page`
  key in `links`, `current_page_url` for simple pagination, RFC 3986 query
  encoding, cursors encoded like `Cursor::encode()`
  (`_pointsToNextItems`, unpadded, PHP JSON escaping). **Cursors issued by
  earlier versions are no longer accepted.**
- Resource `meta` is derived from the paginator array like
  `PaginatedResourceResponse`.
- JSON dates have microseconds (`2026-01-02T03:04:05.000000Z`).
- `abort(code)` without a message renders `{"message": ""}`; 413 says
  `The POST data is too large.`; a 404 for the root route is labelled `/`.
- `ModelNotFoundException(model, [ids])`: message
  `No query results for model [App\Models\User] 1`.
- `personal_access_tokens.tokenable_type` defaults to the model's Laravel
  class (`App\Models\User` instead of `User`). **Upgrade:** run
  `UPDATE personal_access_tokens SET tokenable_type = 'App\Models\User'
  WHERE tokenable_type = 'User'`, or pass `morphClass: 'User'` to the
  `ModelDefinition`.
- New tokens follow Sanctum 4 (`{id}|{40 chars}{crc32b}`); existing tokens
  keep working.
- `cache.value` is `mediumText` and both `expiration` columns are indexed
  (new installs); the `migrations` table is created through the schema
  grammar on every driver.

### Security

- HTTP header names must be tokens and values may not contain CR, LF or NUL
  (response splitting).
- Failed logins for unknown accounts hash a dummy password, so response time
  does not reveal which accounts exist.
- The `url` rule rejects values over 8 192 characters, bounding validation
  time.

### Known gaps

MySQL driver, polymorphic relations, Blade, sessions/CSRF, multipart uploads,
mail, Redis and S3 are planned for Tier 2. Benchmark scenarios 7 (multipart)
and 8 (SSE) wait for those features.

## 0.0.1-dev (Tier 0, Tier 1 / S1–S13)

Walking skeleton and the Tier 1 core: container and zones, configuration,
HTTP kernel, routing, validation, query builder and grammars, the ORM,
schema and migrations, hashing, encryption and auth, multi-isolate serving,
cache and rate limiting, events, queues and scheduling, API resources,
storage, logging and metrics, the `dartisan` CLI with `new` and hot reload,
the testing toolkit, lints and architecture tests.
