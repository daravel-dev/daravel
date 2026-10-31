# Changelog

All notable changes to the Daravel workspace (`daravel`, `daravel_test`,
`daravel_lints`, `daravel_mysql`, `daravel_permission`, `daravel_activitylog`,
`daravel_excel`, `daravel_log_viewer`, `daravel_pulse`, `daravel_payments`,
`daravel_medialibrary`, `daravel_redis`, `daravel_sqlite`, `daravel_postgres`,
`daravel_teorion`, `daravel_livekit`, `daravel_google`, `daravel_teobiefy`, `daravel_s3`,
`daravel_session`, `dartisan_cli`). Versions follow SemVer: breaking changes to the Dart API
wait for a new major version, and Laravel-facing formats change only to
match Laravel more closely.

## Unreleased

### Fixed

- `daravel_session` treated a JSON session (`'serialization' => 'json'`, the laravel/laravel 13 skeleton) as empty and overwrote its row in PHP `serialize()` format, which logged the user out of the Laravel application sharing the store. Both formats are now read, also with `SESSION_ENCRYPT`, and a stored session is written back in the format it has.
- `dartisan e2e:install` overrode only `DB_DATABASE` for `test:e2e --serve`, so a `DB_URL` in the project's `.env` sent `migrate:fresh --seed` to the real database. `playwright.config.ts` now sets `DB_CONNECTION=sqlite` and `DB_URL=sqlite:<E2E_DATABASE>`. **Run `dartisan e2e:install --force` in existing projects, or make the same change by hand.** Projects whose migrations need PostgreSQL or MySQL test a running server with `--url`.
- The tests from `dartisan new` and `make:test` had the same gap with `DB_DATABASE=:memory:`; they now set `DB_CONNECTION=sqlite` and `DB_URL=sqlite::memory:`. Existing projects with a `DB_URL` should change their tests' `env:` the same way.
- `dartisan adopt` treats Laravel 8 to 13 as supported and writes `COMPAT_LARAVEL_VERSION` for the version it finds: an adopted Laravel 8 application answered with Laravel 12's error and validation formats. The old message still said the conformance suite pins Laravel 12.
- Route bindings ran before every route middleware, so a guest got a 404 that told which records exist (and paid for a query) where Laravel answers 401 or 429, and a binder could not read the authenticated user. They now run where `SubstituteBindings` runs: after the cookies, session, CSRF, authentication and rate limit middleware (the new `RunsBeforeBindings` marker), before the rest. **A middleware placed before `auth` on a route no longer sees bindings.**
- The `accepted`, `accepted_if`, `declined` and `declined_if` rules did not exist: the rule string threw, which answered 500 instead of 422. `Rules.accepted()` and the others, in the `RuleBuilder`, and known to `invalid_validation_rule`.
- `Model.toJson` wrote relation keys as declared (`tipeUjian`); Laravel writes `tipe_ujian`. **This changes the JSON of camelCase relations.** `Model.snakeAttributes = false` or `snakeAttributes: false` on a `ModelDefinition` keeps the old keys.
- PostgreSQL date columns without a cast reached JSON as ISO-8601; Laravel gets PDO's text (`2024-01-02 10:20:30`). They are still `DateTime` in Dart (`DatabaseDateTime`). `created_at`, `updated_at`, `deleted_at` and cast columns are unchanged.
- `Schema.hasTable`, `getColumns` and `model:sync` looked only in the current PostgreSQL schema, and missed partitioned tables and views: `schema.table` now works as in Laravel, and `model:sync` and `model:show` see views.
- `model:sync` typed `Cast.decimal` as `String`, and on PostgreSQL gave `String` for dates and booleans, whose getters crashed, and `int` for `interval`. Types now follow what each driver returns.
- Paginator links always carried `page`, which Laravel 8 to 11 do not write: it now follows `COMPAT_LARAVEL_VERSION` (12 and later).
- Paginator labels were always English: they come from `pagination.previous` and `pagination.next` when the application has them. `validation.*` lines (`withTranslations`, `lang/<locale>.json`) now win over the bundled messages of the same locale.

### Added

- `SessionGuard` (`auth.session<User>('web', provider)`, `daravel_session`): Laravel's session guard on the same `login_web_<sha1>` key and, from `COMPAT_LARAVEL_VERSION=12`, `password_hash_web`. A login holds on both sides of a shared store. Remember-me cookies are not supported yet.
- `Cast.decimalString(places)`: Laravel's `decimal:N`, a string rounded half up without a double.
- `DB_SEARCH_PATH` (or `DB_SCHEMA`) and `Schema.hasView`.
- `Teobiefy.api(..., includeDataCount: false)`.
- `SESSION_SERIALIZATION` (`php` or `json`): the format of new sessions, `php` by default and `json` with `COMPAT_LARAVEL_VERSION=13`. `dartisan adopt` copies it from the Laravel project's `config/session.php`, because a Laravel application upgraded to 13 keeps `php` unless it added the key.
- `bench/interop/laravel_matrix.sh`: Daravel beside real Laravel 8 to 13 applications on one database (sessions both ways in both formats, encrypted or not; `Crypt` and bcrypt both ways; 422, 404 and 405 bodies byte for byte; `dartisan adopt`).

## 1.20.0

A new logo, and the items of Blueprint #58 (runtime hardening and
streaming) that 1.18 and 1.19 had not already shipped: a coordinator port
that kept a single-isolate server alive, connection-pool sizing in
`doctor` for MySQL and MariaDB, a single-pass PHP JSON encoder and
streamed JSON arrays from the query builder.

### Fixed

- `Application.serveWith` with one isolate and an embedded queue worker or scheduler (`SERVER_EMBED_QUEUE` / `SERVER_EMBED_SCHEDULER`) left the coordinator's `ReceivePort` open after the server stopped, so the process did not exit on its own; the port is closed with the embedded workers (`Coordinator.isListening`).

### Added

- `dartisan doctor` compares the connection pool with the server's `max_connections` on MySQL and MariaDB too (`SHOW VARIABLES LIKE 'max_connections'`), and the product counts `APP_PROCESSES` and the embedded queue worker and scheduler: `DB_POOL_SIZE × (APP_ISOLATES + embedded) × APP_PROCESSES`. The MySQL/MariaDB CI job runs the doctor tests.
- `Response.json(phpCompatible: true)` encodes in one pass (`PhpJsonEncoder`): the same bytes as before (a 2 000-value randomised test and the fixtures check it), without the intermediate string and its rewrite. 1 000 rows × 40 columns (1.24 MB of PHP JSON, AOT, SQLite): 17–18 ms against 21–23 ms (plain JSON of the same rows: 9–10 ms).
- `Response.streamJson(items, wrap:, phpCompatible:)` (Laravel's `response()->streamJson()`), `jsonArrayBytes()` and `QueryBuilder.streamJson(chunk:)`: a JSON array written as the rows arrive, a page at a time, byte for byte what `Response.json` writes for the collected list, so a large result set is never held whole and no model is built. It bounds memory, not CPU: 30 ms streamed against 23 ms for `get()` plus `Response.json` on the same 1 000 × 40 rows.
- `bench/bin/wide_profile.dart` reports `encode_php_json_ms`, `php_json_bytes`, `stream_json_ms` and `stream_json_php_ms`.

### Changed

- New Daravel logo: an infinity loop, blue for Dart and red for the Laravel heritage, framed
  in gold ornament, replacing the geometric dragon. `docs/brand` now starts from the
  illustration in `docs/brand/source`: `tool/brand/generate.dart` crops and rounds its tile,
  keys the transparent and single-colour marks out of the navy background and keeps the
  stroke-built wordmark for the lockups. `daravelLogoDataUri` and `daravelFaviconDataUri`
  carry the new icon, so the starter's welcome page and the API reference page show it.

## 1.19.1

A fix-only patch: `db:replicate` no longer fails a sync when an application
writer keeps the write lock past `busy_timeout` at the moment the replicator
rolls its log over.

### Fixed

- `db:replicate` no longer fails a sync when an application writer takes the write lock
  between the replicator's checkpoint and its roll-over and keeps it past `busy_timeout`:
  the roll-over waits for the next sync, as it already did when a reader blocked the
  checkpoint.

## 1.19.0

The rest of what a Laravel 8 port onto 1.18 asked for, each checked against
Laravel on GitHub: the `date_format` rule, sessions that Laravel 11 to 13
would write by default (the `sessions` table, `SESSION_ENCRYPT`,
partitioned cookies), and `json_encode` bytes where clients compare them.
`daravel_session` now defaults to `SESSION_DRIVER=database`.

### Fixed

- `db:replicate` no longer fails its first sync when the application holds
  the write lock for longer than `busy_timeout`: the marker row it writes to
  start a log is retried, since that writer is writing the log anyway.
- `ProcessSupervisor` no longer takes a socket connected to itself for a
  ready child: on Linux, dialling a free port of the ephemeral range can
  open a TCP connection to itself.

### Added

- The `date_format` validation rule (`date_format:Y-m-d,d/m/Y`, `Rules.dateFormat`), as Laravel's `validateDateFormat`: the value must read with PHP's `createFromFormat('!' . $format)` and format back exactly, so `2026-02-30` fails `Y-m-d`; `phpDateMatchesFormat`.
- `daravel_session`: `SESSION_ENCRYPT` (the payload encrypted with `Crypt`, as Laravel's `EncryptedStore`) and `SESSION_PARTITIONED_COOKIE` (`Partitioned` on the session and `XSRF-TOKEN` cookies); `Response.withCookie(partitioned:)`.
- `teobiefy.aes:php` and `TeobiefyAesCbc.encrypt(phpJson:)`: the clear text and the envelope written as PHP's `json_encode`.
- `Response.json(phpCompatible: true)` writes a `PhpObject` as an object, so `const PhpObject('stdClass', {})` is `{}` (`(object) []`) while an empty map stays `[]`.

### Changed

- `daravel_session` defaults to `SESSION_DRIVER=database`, as laravel/laravel 11 to 13 (`config/session.php`); 1.18 took `file` from an old skeleton. Set `SESSION_DRIVER=file` to keep the files, or run `CreateSessionsTable`.

## 1.18.1

Two Laravel parity fixes found while moving a Laravel 8 port onto 1.18.0:
error bodies are written byte for byte as Laravel writes them, and the
validator stops on an attribute after a failed `required` as Laravel does.

### Fixed

- Error bodies are written as Laravel 8 to 13 write them
  (`Handler::prepareJsonResponse`): pretty-printed with four spaces and `/`
  unescaped for every HTTP error, the 500 and the 413, while 401
  `Unauthenticated.` and 422 stay compact. The JSON values do not change;
  clients that compare bytes now get the same body from both frameworks.
- The validator stops on an attribute once one of Laravel's implicit rules
  fails (`required`, `present`, `filled`, `required_*`, as
  `Validator::shouldStopValidating`): `{"code": null}` against
  `required|string` now reports only "The code field is required.", not
  "must be a string" too. `unique` and `exists` are not queried for an
  attribute that already failed another rule
  (`hasNotFailedPreviousRuleIfPresenceRule`).

## 1.18.0

Lessons from porting a Laravel 8 application to Daravel, made general.
`daravel_session` joins the release line: Laravel's sessions in a file or the
`sessions` table, encrypted cookies and CSRF, shared with a Laravel
application on the same `APP_KEY`. `COMPAT_LARAVEL_VERSION` answers with the
error and validation bodies of Laravel 8 to 13, the conformance suite now
pins Laravel 13, and `Crypt.encrypt` carries PHP `serialize()` so values move
between the two frameworks. `APP_PROCESSES` runs several server processes
behind a proxy for endpoints that do not scale across isolates, embedded
workers share the server's coordinator, and the MySQL driver reads rows in
half the time.

### Added

- From a real migration of a Laravel 8 application (review #56):
  `DB_STRICT`, `DB_SQL_MODES` and `DB_ISOLATION_LEVEL` on MySQL and
  MariaDB, with the `sql_mode` Laravel sets (`'strict' => false` lets
  legacy inserts without every `NOT NULL` value through, as in Laravel);
  `Request.current` for the request being handled anywhere in its call
  chain; asynchronous exception renderers; `doctor` flags packages
  resolved on another operating system (a `pub get` on the Windows host
  of a WSL or DDEV project); and the guide shows API groups outside
  `/api`.
- SQLite replication (Blueprint #30): `dartisan db:replicate` streams a
  SQLite database to a storage disk (S3, R2, ...) as it changes, as
  Litestream does: a page-exact snapshot, then the committed frames of the
  write-ahead log, checked as SQLite checks them, and a new snapshot
  whenever continuity cannot be proven. `db:restore` rebuilds the newest
  state or the state as of a moment (`--at`), and `--if-missing` suits a
  container start. Chaos tests restore under concurrent writes and after
  the replicator is killed.
- `daravel_payments` (Blueprint #40): Midtrans (Snap), Xendit (invoices)
  and Stripe (Checkout) behind one `Payment.checkout()`. Webhooks are
  verified as each gateway documents it (Midtrans' SHA-512 signature,
  Xendit's callback token, Stripe's timestamped HMAC with its five-minute
  tolerance) and applied exactly once: an idempotency log, the payment
  row locked, the amount compared with the order's, status moves that
  only go forward, and `PaymentPaid` (and failed, expired, refunded,
  amount mismatch) dispatched after the commit. `Payment.fake()`,
  `dartisan payment:check` for a missed webhook, and the
  `CreatePaymentTables` migration.
- The strangler fig proxy (Blueprint #29): `withUpstream()` puts Daravel
  in front of the Laravel application being migrated. Routes Daravel has
  answer from Daravel; every other request, whatever its method, streams
  to Laravel unchanged (bodies, cookies, redirects, compression), with
  `X-Forwarded-*` headers, 502 when Laravel is down and 504 when it is too
  slow. `dartisan route:diff` shows which Laravel routes Daravel answers
  already, from `php artisan route:list --json`.
- `daravel_teobiefy`: the OpenSSL AES-256-CBC `{data_enc, iv}` envelope of Laravel APIs that encrypt with `openssl_encrypt`: `TeobiefyAesCbc`, `withTeobiefyAesCbc()` (key from `OPENSSL_KEY`) and the `teobiefy.aes` middleware (`:body`, `:decrypt`), checked against NIST SP 800-38A and `openssl enc`; no MAC, legacy compatibility only (review #56 §2.6).
- `Cast.dateTimeFormat` (Laravel `datetime:FORMAT` / `date:FORMAT`, formatted in UTC as Laravel 8 to 13 do) and `formatPhpDate`; appends keep an existing attribute's position. No `COMPAT_LARAVEL_VERSION` switch is needed: the behaviour is the same in every version (ADR-025 §4).
- `APP_PROCESSES` / `serve --processes=N` (ADR-027): several server processes on consecutive ports behind a reverse proxy, for endpoints that gain nothing from more isolates (shared heap); refused with per-process stores unless `APP_PROCESSES_ALLOW_UNSHARED_STATE=true`.
- `package:daravel/foundation.dart`, `http.dart`, `database.dart`, `auth.dart`, `validation.dart`: subsets of the barrel for files whose names collide with it.
- `doctor --fix-tooling`.
- `daravel_session` (Blueprint: sessions, Tier 2 gap closed): Laravel-compatible sessions in a file or the `sessions` table (`base64(serialize($attributes))`), `EncryptCookiesMiddleware` with Laravel's cookie value prefix, `VerifyCsrfTokenMiddleware` (`_token`, `X-CSRF-TOKEN`, `X-XSRF-TOKEN`, the `XSRF-TOKEN` cookie, 419), `request.session`, flash data, `regenerate`, `invalidate`, `CreateSessionsTable`; `withSession()` registers the `web` middleware group.
- `Crypt.encrypt`/`decrypt` use PHP `serialize()` like Laravel (ADR-026): values encrypted by either framework are read by the other; JSON payloads from 1.17 still decrypt.
- `COMPAT_LARAVEL_VERSION` (8 to 13, default 12; ADR-025): the Laravel
  major whose wire formats the application answers with. 10 to 13 share
  them (checked against each release's source). 9 uses the older
  validation messages (`The email must be a valid email address.`); 8
  also answers `The given data was invalid.` for every 422, an empty
  404 message and `... not supported for this route.` for a 405.
- `Request.cookies`, `Request.cookie(name)`, `Request.hasCookie(name)`,
  `Response.withCookie(...)` and `Response.withoutCookie(name)`, written in
  the format Laravel 11 to 13 send (Symfony's `Cookie`).
- `Response.json(data, phpCompatible: true)`: the bytes of PHP's
  `json_encode()` (`\/`, `\u` escapes, `[]` for an empty map), in one pass
  over the native encoder's output; `phpJsonFromDart` and `phpRawUrlEncode`.
- `isolateSizingAdvice`: `serve` notes one HTTP isolate in production on a
  machine with more cores, and `doctor` says which shared stores replace
  state kept in statics.
- Benchmark scenario 13 (1 000 rows of a 40-column table) and
  `bench/bin/wide_profile.dart`; the harness also runs against MySQL and
  MariaDB (`--database=mariadb://...`).
- `CACHE_PROCESS_MAX_ENTRIES` bounds the `process` cache store (10 000 by
  default, fixed before); `doctor --production` warns when a JWT denylist
  lives in the `memory` or `process` store.

### Changed

- `daravel_mysql` reads rows in one pass instead of three maps per row: a 1 000 × 40 `SELECT` takes about half the time (21 ms to 10 ms).
- The database cache store writes `forever` entries as ten years from now (Laravel's `DatabaseStore::forever`), not the constant 9999999999 that overflowed MySQL's `integer` column.
- `Request.replaceCookies`, `Response.withHeaderList`, `Encrypter.keys`.
- Boot runs with the application's container as `Container.current`, so
  `App`, `Config` and `env` work in providers, bindings and routing
  callbacks (they threw "No Daravel container is active" there).
- Embedded queue and scheduler isolates share the server's coordinator
  (process cache, rate limits, locks); each had its own before, so a token
  revoked by a job stayed valid for the HTTP workers.
- The conformance suite cites laravel/framework 13.x; Laravel 10 to 12
  write the same formats (ADR-025).
- `no_sql_string_interpolation` reports `raw`, `select`, `statement` and
  `insertGetId` only on a database receiver (`DB`, a connection or query
  builder, a builder chain), and accepts interpolation of literals and
  `const` names of the file. `no_mutable_static_in_app` also reports a
  final static that starts as an empty collection (`static final _hits =
  <String, int>{}`), and both of its messages name the shared stores.
- `phpJsonEncode` (cursor pagination) runs in one pass instead of one
  write per character.
- `daravel_excel` depends on `xml` ^7.0.0 (was ^6.6.1): pub.dev took 10
  points off 1.17.0 because the constraint left out xml 7.

## 1.17.0

`daravel_pulse` joins the release line: a dashboard of the running
application after Laravel Pulse, merged across its worker isolates through
the coordinator's new worker reports. `dartisan` gains `test:stress`, an
application under load with a report safe to publish, and `e2e:install`,
`make:e2e` and `test:e2e`, Playwright suites that CI now runs against the
starter.

### Added

- `dartisan test:stress` (Blueprint #45): your application under load,
  wherever it runs. It finds the scenarios the application answers (health
  check, ping, a 404, `/api/auth/me` with a synthetic user's token, a
  rate-limited login, `--path` routes), warms up, runs rounds over several
  connections and client isolates, and reports throughput (mean ±
  standard deviation) and p50/p95/p99 latency. A 5xx, a request without a
  response, an unexpected status, `--max-p95` or `--min-rps` fails it, for
  CI. `--export-public` writes a report safe to publish from a list of
  allowed fields: never the target, tokens, the synthetic user or custom
  routes.
- `dartisan e2e:install`, `make:e2e` and `test:e2e` (Blueprint #46): a
  Playwright suite in `tests/e2e`, over HTTP and in Chromium: health and
  404 bodies, token authentication from register to logout, Laravel's 422
  body, login rate limiting, the welcome page without console errors and
  its security headers. `test:e2e --serve` starts the application on a
  fresh `database/e2e.sqlite` first; `--url` tests a DDEV site or staging.
  The starter carries the suite and CI runs it on every commit.
- `daravel_pulse` (Blueprint #32): a dashboard at `/pulse` after Laravel
  Pulse. Requests by minute (count, server errors, latency), slow requests
  by route pattern, slow queries by SQL (never the bindings), exceptions by
  class and first application frame with their trace, slow and failed jobs,
  queue sizes and the `failed_jobs` of the period, over 1, 6 or 24 hours.
  Each isolate records in bounded memory; under a supervisor the workers
  send their reports to the coordinator, so the page shows the whole
  process. Laravel Pulse's threshold keys
  (`PULSE_SLOW_REQUESTS_THRESHOLD`, ...), the `viewPulse` gate in the
  examples, 403 outside local without middleware, and a nonce-based CSP
  with no external assets. `dartisan pub:add pulse` installs it.
- `WorkerReportService` and `WorkerReports` in `daravel`: a coordinator
  service that keeps the latest report of each worker isolate by topic and
  forgets a worker that exits, for pages that show the whole process.

### Fixed

- `Application.shutdown()` after a boot that failed or never ran no longer
  throws `LateInitializationError` for `logger`, which hid the real error
  when a test's tearDown shut such an application down.

## 1.16.0

`daravel_medialibrary` joins the release line (first published as 1.15.0):
files and images attached to models on spatie/laravel-medialibrary's table
and file layout, with image conversions in pure Dart. `dartisan` gains
`security:audit`, a black-box check of a running server for deployment
mistakes, a `coordinator:stats` that reads the running server, and a
distroless Docker image. `apps/virtual_classroom` shows the first-party
packages working together. Every package now ships an example, and
`tool/publish_checks.dart` keeps the publish order and examples in place,
so every package scores its full pub points again.

### Added

- `daravel_medialibrary` (Blueprint #37): files and images attached to
  models with spatie/laravel-medialibrary v11's `InteractsWithMedia`,
  collections (`singleFile()`, accepted MIME types, their own disks) and
  conversions, on Spatie's `media` table and file layout
  (`<id>/<file>`, `<id>/conversions/<file>-<conversion>.jpg`), so a Laravel
  application on the same database and disk reads, serves and deletes the
  media Daravel adds and the other way round
  (`bench/interop/medialibrary.sh`). Images are converted in pure Dart in
  a separate isolate, with Spatie's resize rules (`width`, `height`, `fit`
  and `crop` in order, JPEG at GD's quality by default, EXIF rotation);
  queued conversions run as `PerformConversionsJob`. File names are
  cleaned and refused as Spatie does (`shell.php.jpg` included);
  `media:regenerate` and `media:clean`.
- `apps/virtual_classroom` (Blueprint #47): an example application in which
  the first-party packages work together. Teachers schedule lessons in
  their classrooms; students join them in LiveKit rooms with a token
  signed per participant (the teacher as the room's admin), from 15
  minutes before the start; published lessons are put in Google Calendar
  with the students as guests by a queued job. Roles, query filters and
  the activity log are wired in, and the feature tests fake LiveKit and
  Google over `Http.fake()`.
- `dartisan build --docker --distroless`: the generated `Dockerfile` runs
  on `gcr.io/distroless/cc-debian12:nonroot` (no shell or package manager,
  non-root; about 84 MB for a new project), its writable directories
  prepared in the build stage.
- Every published package lists its GitHub Sponsors page as `funding` on
  pub.dev.
- `dartisan coordinator:stats --url=<server>/metrics` reads the running
  server's coordinator instead of the command's own (always idle) one: the
  queue against its limit, refused calls, and round trips by service with
  p50/p99, and says what to do (`CACHE_LIMITER=database`,
  `CACHE_PROCESS_L1_TTL`, Redis). `/metrics` gains
  `coordinator_call_duration_seconds{service}`,
  `coordinator_call_timeouts_total{service}`,
  `coordinator_in_flight_peak` and `coordinator_max_queue`.
- `dartisan security:audit`: a black-box audit of a running server for
  deployment mistakes, with single harmless requests: security headers,
  version banners, `.env` / `.git` / database / logs served, path
  traversal, `TRACE`, CRLF injection, stack traces in errors, deep JSON,
  CORS reflecting any origin, cookie flags, `/metrics` and the log viewer
  left open, plain HTTP. Only content that proves a leak counts. Reports
  for the terminal, JSON or SARIF (GitHub code scanning); exits 1 at
  `--severity` for CI.
- `THIRD_PARTY_NOTICES.md` (and one in `daravel`, `daravel_test` and
  `daravel_medialibrary`): the MIT notices of the Laravel validation
  messages Daravel reproduces and of the Spatie behaviour
  `daravel_medialibrary` follows.
- `daravel_google` and `daravel_teobiefy` ship an example.

## 1.15.0

Two first-party packages join the release line: `daravel_excel` (XLSX and
CSV exports and imports with Laravel Excel 3.1's concerns, streamed in
constant memory and checked against Laravel Excel both ways) and
`daravel_log_viewer` (a page that reads the log files from their end,
filters them and follows them live). `dartisan pub:add` installs any
first-party package by name or alias and wires it into the project. A
command in an application with `withPermissions()` no longer hangs after
its work is done.

### Added

- `daravel_log_viewer` (Blueprint #53): `withLogViewer(middleware: [...])`
  serves a page that reads the application's log files: Daravel's daily
  JSON logs and Laravel's Monolog files, newest first, filtered by level
  or text, with stack traces, and new entries live over server-sent
  events. Files are read from their end a block at a time (the newest 50
  entries of a 500 MB file in under a millisecond, 17 MB of process
  memory); secrets are masked in context and text; only `.log` files of
  the folder open; the page has a nonce-based Content-Security-Policy and
  no external assets, and answers 403 outside local until it has
  middleware.
- `daravel_excel` (Blueprint #39): XLSX and CSV exports and imports with
  Laravel Excel 3.1's concerns. Exports stream from a query (a chunk at a
  time), a collection or a stream to a download, a disk or bytes, at a
  constant 24 MB for 10 000 to 500 000 rows; imports map rows to models
  (one by one or in batches), collections or callbacks, validate each row
  with Daravel's rules and report failures with their sheet row numbers
  (a 422 keyed `<row>.<attribute>`), in one transaction. XLSX is written
  and read with a streaming ZIP and XML pipeline of its own (a limit
  against ZIP bombs), CSV as PhpSpreadsheet writes and reads it;
  `make:export` and `make:import`. `bench/interop/excel.sh` checks the
  files against Laravel Excel.
- `dartisan pub:list`, `pub:search` and `pub:add` (alias `install`): find
  and install first-party packages by name or alias. `pub:add` adds the
  dependency, registers the package in `bootstrap/app.dart`, patches its
  migrations and commands into the registries and documents its settings
  in `.env.example`; the database and Redis packages go through
  `db:install` and `redis:install`. Typos stop with a suggestion, and a
  package outside Daravel is added only after confirmation or `--yes`.

### Changed

- `ValidationException` can be extended (`base` instead of `final`), so a
  package can throw a validation error of its own that the exception
  handler renders as Laravel's 422 (`ExcelValidationException`).

### Fixed

- A command in an application with `withPermissions()` (any package that
  subscribes to a broadcast channel at boot) never exited: the package
  cancelled its subscription after the application had closed the
  `Broadcaster`, which then opened a new port that nothing closed.

## 1.14.0

Two first-party packages join the release line: `daravel_activitylog`
(spatie/laravel-activitylog v4 on its `activity_log` table, checked against
Laravel 12 with Spatie both ways) and `daravel_s3` (a `Storage` disk on S3
and S3-compatible stores, signed with SigV4 in pure Dart), both first
published as 1.13.0. The server gains limits that hold without extra
middleware (`HTTP_MAX_BODY`, `HTTP_IDLE_TIMEOUT`, a WebSocket frame limit)
and database timeouts (`DB_CONNECT_TIMEOUT`, `DB_QUERY_TIMEOUT`). A review
of the queue worker, the scheduler, storage, mail, the coordinator and the
packages fixed what could crash a worker, leak a connection or a secret,
or let a client's input go further than intended; the details are below.

### Added

- `DB_CONNECT_TIMEOUT` and `DB_QUERY_TIMEOUT` (seconds, `0` for none) for
  PostgreSQL and MySQL: the PostgreSQL statement timeout was a fixed 30 s,
  which cancelled a long `CREATE INDEX` in a migration, and MySQL had none
  at all, so a statement stuck on a lock wait or a half-open connection
  held its pooled connection for ever and, once the pool was full, every
  request on the isolate queued behind it. `daravel_mysql` now passes the
  timeout to `mysql_dart`, which kills the query on expiry.
- `HTTP_IDLE_TIMEOUT` (`ServeOptions.idleTimeout`, 60 s): how long a
  keep-alive connection may sit without a request before the server
  closes it, so idle sockets a client opens and never uses are bounded;
  the field existed but had no environment setting.
- A WebSocket frame limit (`router.ws(..., maxPayloadBytes:)`,
  `Response.webSocket(maxPayloadBytes:)`, 1 MiB by default): a larger
  frame fails the connection as it arrives. `dart:io` sets no limit of
  its own unless the build defines one, so one client could make a
  worker buffer a frame of any size. The Pusher server caps frames at
  `REVERB_APP_MAX_MESSAGE_SIZE` plus 1 KiB, before buffering instead of
  after.
- `HTTP_MAX_BODY` (`ServeOptions.maxBodyBytes`, 50 MiB; `0` for none): a
  body limit every request starts with (`Request.defaultMaxBodyBytes`,
  on served and synthetic requests alike), so an
  application that does not register `BodyLimitsMiddleware` (which
  tightens it to 1 MiB for JSON and forms) still refuses a 10 GB upload
  with `413` instead of buffering it in memory. A declared
  `Content-Length` above it is refused before the body is read.
- `daravel_livekit`: webhooks older than `maxAge` (five minutes, 30 s of
  skew either way) or dated in the future are refused with 401, closing
  the replay window a token's lifetime left open
  (`LivekitWebhookReceiver.maxAge`, `Livekit.webhook(request, maxAge:)`);
  `Livekit.webhook` also remembers each event id in the cache for that
  window and refuses a repeat, so a replay inside the window is refused
  too.
- `daravel_livekit`: `RoomServiceClient` retries a Twirp call whose
  connection failed before it was sent, or that LiveKit answered 502
  or 503, up to `retries` (2) more times with exponential backoff and
  jitter from `retryDelay` (200 ms); a timeout or any other answer is
  final, since the call may have been processed. The HTTP client's
  `ConnectionException` carries `isTimeout` for that distinction.
- `daravel_activitylog` (Blueprint #38): spatie/laravel-activitylog v4 on
  its `activity_log` table, so Laravel and Daravel share one log
  (`bench/interop/activitylog.sh` checks it against Laravel 12 with Spatie
  4.10, both ways). `LogsActivity` with `ActivityLogObserver` records
  `created`, `updated` (with `old` values), `deleted` and `restored` as
  Spatie does; `LogOptions` has Spatie's builder methods (`logOnly` with
  relation and JSON attributes, `logOnlyDirty`, `dontSubmitEmptyLogs`,
  ...); `activity()` logs by hand with placeholders; the request's user is
  the causer; `LogBatch.within`; `Activity` with Spatie's scopes,
  `subject()` and `causer()`; `activitylog:clean`. The activity is written
  in the model's transaction, and what Spatie keeps in singletons (a
  disabled log, a forced causer, a batch) is scoped to a zone.
- `Model.getChanges()`, Laravel's `getChanges()`: the attributes the last
  `save()` wrote.
- `daravel_s3` (Blueprint #52): a `Storage` disk on AWS S3 and
  S3-compatible stores (Cloudflare R2, MinIO, DigitalOcean Spaces, Google
  Cloud Storage), configured from Laravel's `AWS_*` variables with
  `withS3()`. Requests are signed with AWS Signature Version 4 in pure Dart
  (checked against AWS's published S3 examples), bodies stay binary and
  downloads stream. `putStream` holds one 8 MiB part at most and becomes a
  multipart upload (aborted on failure) for longer streams; `copy` is
  server side, `delete` batches `DeleteObjects` per thousand keys, and
  `makeDirectory` writes the `dir/` marker Laravel writes.
  `temporaryUrl` and `temporaryUploadUrl` presign `GET` and `PUT`, and
  `temporaryUploadForm` signs a `POST` policy that caps an upload's size
  and content type (`content-length-range`), all on the
  testable clock and work on `Storage.fake()` disks too. One contract suite
  runs against `LocalDisk`, `MemoryDisk` and `S3Disk`, over an in-process
  S3 that verifies every signature, and on RustFS in CI.

- `daravel_teobiefy` (Blueprint #34, phase 1): the encrypted API payloads
  of teobiefy protocol v1, as a Laravel API implements it, so that API's
  clients talk to Daravel unchanged. `Teobiefy.handshake` derives a pair of session
  keys per client with X25519 (libsodium's `crypto_kx`), kept in the cache
  under Laravel's key with a sliding TTL; the `teobiefy` middleware opens
  `data_enc` requests and seals the `data` of JSON responses with
  ChaCha20-Poly1305 IETF (zstd-framed, base64 or `enc_v: 2`), and answers
  `409 SESSION_KEY_REQUIRED` rather than plain data. Checked against
  vectors from libsodium and frames read by the reference `zstd`.
  `withTeobiefy()` reads Laravel's `LIBSODIUM_SESSION_TTL`,
  `LIBSODIUM_PAYLOAD_V2_ENABLED`, `LIBSODIUM_LEGACY_KEY_ENABLED` and
  `LIBSODIUM_LEGACY_KEY`.
- `Request.merge(input)` and `Request.replace(input)`, Laravel's
  `$request->merge()` and `$request->replace()`: change the body's fields
  that `all()`, `input()` and validation read.

### Changed

- `HmacJwtKey` (so `JwtCodec.hs256`) refuses an empty secret with
  `ArgumentError`: HMAC over an empty key signs and verifies like any
  other, so a secret that was never set accepted tokens anyone could
  mint. The guard's `JWT_SECRET` already had to be 32 bytes; this is the
  floor for every other use of the codec.
- `dartisan migrate:rollback`, `migrate:reset`, `db:seed` and
  `migrate --seed` refuse to run under `APP_ENV=production` without
  `--force`, as artisan's do (plain `migrate` is unchanged); a
  framework error in any command is one `Error:` line and exit 1 rather
  than a stack trace and exit 255 (`--verbose` or `DARAVEL_DEBUG=true`
  keeps the trace); `mcp:serve` also refuses `down` and `env:encrypt` in
  production.
- `dartisan doctor --production` fails unless `APP_ENV=production`: the
  checks that only apply there (debug mode, the key, `/metrics`, the
  queue, hashing) were skipped under any other environment, so the gate
  passed on a configuration never deployed as such. Under production it
  now also reports a missing `APP_KEY` (error), `HASH_VERIFY=false`,
  `BCRYPT_ROUNDS` below 10 and `HTTP_MAX_BODY=0` (warnings), and a
  plain-`http` `APP_URL`,
  `HASH_DRIVER=pbkdf2` and secrets in a plain `.env` (notes). A missing
  `.env` is a note when `APP_ENV` comes from the OS environment, so the
  gate passes inside the image `build --docker` produces.

### Fixed

- `daravel_s3`: a request that times out is aborted (its socket used to
  wait for an answer nobody read, out of the pool for as long as the
  peer kept it); a response body that goes quiet for the client's
  `timeout` is cut off with `ConnectionException` instead of holding the
  handler for ever; a request S3 answered 500, 502, 503 (`SlowDown`) or
  504, or whose connection failed before a response, is sent again up
  to `retries` (3) more times with exponential jittered backoff from
  `retryDelay` (100 ms), as the AWS SDKs do; a connection reset during
  a send now surfaces as `ConnectionException` (the catch bound to
  Daravel's `HttpException`, not `dart:io`'s, so it escaped unwrapped);
  and `readStream` downloads get the same quiet-body timeout as `get`.
- `DB.transaction(attempts: n)`: the after-commit callbacks ran inside
  the retry, so a callback failing with a deadlock or serialization error
  re-ran the body after it had committed, committing its writes again.
  They now run after the retry scope; as in Laravel, the first callback
  to throw stops the rest and surfaces to the caller.
- `daravel_permission`: `hasRole`, `hasAllRoles` and `hasExactRoles`
  given a `Role` of another guard no longer match a role of the same name
  under the model's guard (Spatie compares `Role` objects by key).
- `daravel_teorion`: `scopes[0][params]=x` (not a map) is read as no
  parameters instead of a 500.
- SQLite: a connection whose setup fails after the file is opened (a file
  that is not a database, one that stays busy) closes its handle; it used
  to stay open, keeping the file locked, and every retry leaked one more.
- `MemoryStore` sweeps expired locks once there are `maxEntries` of them;
  a lock that expired without a release (its holder crashed) stayed for
  ever, so one lock name per order or user only grew the map
  (`MemoryStore.lockCount`).
- `ProcessRateLimitStore` sweeps the expired leases and blocks of keys it
  no longer limits once `maxKeys` (10 000) are tracked, and keeps batch
  sizes in order of last use, dropping the older half when full; every
  key a worker ever limited (one per client IP) stayed until it was asked
  for again (`ProcessRateLimitStore.trackedKeys`).
- `daravel_permission`: a revocation is relayed through the coordinator
  to the other worker isolates, which drop their caches as soon as the
  message lands instead of at their next read of the shared version (up
  to a second); the version stays as the fallback.
- `daravel_permission`: the per-isolate access cache is bounded
  (`PermissionRegistrar.maxCachedModels`, 10 000); one entry per model
  ever checked stayed until the isolate exited.
- `daravel_google`: once Google answers `invalid_grant`, the refresh
  token is remembered as revoked on the OAuth client (`GoogleOAuth.isRevoked`)
  and by the `UserCredentials` (`revoked`), so neither credentials kept
  alive nor ones built afresh per request ask the token endpoint again;
  `replace` installs the token of a new consent and discards a refresh
  of the old one still in flight.
- `daravel_google`: `Google.serviceCalendar()` shares one service-account
  token per isolate, scopes and subject (`Google.serviceCredentials`,
  `ServiceAccountCredentialsCache`); it used to sign an RS256 assertion
  and call Google's token endpoint on every call. `UserCredentials` stores
  a refreshed token before keeping it, so a store that fails is retried on
  the next call instead of leaving memory and database apart.
- Scheduler: `withoutOverlapping` locks name the task and its expression
  and are taken separately from the single-server minute lock (a task
  with both used to take only the minute's lock, so nothing prevented
  overlap); an unnamed closure with `withoutOverlapping` is refused at
  run, since every unnamed closure shared one lock. `LocalDisk.putStream`
  writes through a temporary file, so a failed stream leaves no
  truncated file.
- Scheduler: `schedule:work` starts each minute's run without waiting
  for the previous one, as Laravel's does, so a task that hangs or takes
  minutes no longer stops the scheduler or skips the minutes in between
  (`withoutOverlapping` keeps such a task from running beside itself).
- Queue worker: a row whose payload does not decode is removed and
  recorded in `failed_jobs` (it was re-reserved after `retry_after` and
  crashed every worker in turn), a job whose `fromJson` throws fails
  like an unknown job, a transient database or cache error is logged and
  waited out instead of ending the worker, and a job released after a
  timeout, whose handler is still running, stops the worker with exit
  code 1 for a restart so attempt 2 does not run beside attempt 1.
- Validation: `min`, `max`, `between` and `size` measure a string by
  its numeric value when the attribute also carries `numeric` or
  `integer`, as Laravel does; every form and query input is a string,
  so `numeric|max:100` passed `"500"` by its three characters. The
  validators `dartisan client:flutter` generates measure it the same way.
- Storage, mail and schedule: a disk path with a control character (a
  NUL, which Windows truncates a name at) is refused; a failed SMTP
  `AUTH LOGIN` no longer quotes the base64 password into its exception,
  which reached `failed_jobs` and the log; a `MailAttachment` content type
  with a line break is refused (header injection); the STARTTLS handshake
  is bounded by `MAIL_TIMEOUT`; and a cron expression with both day
  fields set (`0 0 1 * 1`) matches either day, as Vixie cron and Laravel
  do (it required both, so such schedules never ran).
- The error of a malformed `DB_URL` masks the password
  (`ConnectionConfig.redactUrl`); it used to quote the whole URL,
  `user:secret@` included, into `doctor`'s output and the boot log.
- The coordinator bounds the last frames it keeps for cache channels
  (`ChannelMembershipService.maxCachedFrames`, 10 000, expired first);
  a frame stayed until its channel was read again, so one cache channel
  per user or document grew it without bound.
- A worker isolate that exits (a crash, a kill) no longer leaves ghosts
  behind in the coordinator: its presence-channel members vanish from
  `users` and `channel` and its broadcast ports are dropped
  (`WorkerAwareService`, `Coordinator.forgetWorker`; `join` and
  `subscribe` carry the worker's name). Members it held used to stay in
  every presence channel for ever, and every respawn added a dead port
  the fan-out kept sending to.
- Supervisor: a worker that does not become ready within `readyTimeout`
  is killed; it used to go on booting, bind the port and serve untracked
  next to its replacement. A worker that reports `WorkerFailed` while
  being respawned is counted once (its exit used to be counted again and
  respawned twice), and a `WorkerReady` nobody waits for is ignored. `stop()` returns at once when every worker is
  already gone instead of waiting for the shutdown deadline, a respawn
  that completes during a drain is drained, and a message with an
  unknown worker index is dropped instead of thrown out of the inbox
  listener (on the main isolate, where that ends the process).
- Coordinator: a service answer that cannot be sent to a worker (a
  `ReceivePort`, a socket) is answered as a `CoordinatorException`
  instead of thrown out of the coordinator's port listener, which runs
  on the supervisor's main isolate. `RemoteCoordinatorChannel.call` after
  `close()` fails at once (it used to wait for the timeout and restart
  the sweep timer).
- `dartisan migrate --seed` runs the root seeder; the flag was declared
  and never read (`migrate:fresh --seed` worked).
- `daravel_livekit` refuses to work with an empty API secret: HS256 over
  an empty key verifies whatever was signed with one, so a server whose
  `LIVEKIT_API_SECRET` was unset accepted webhooks anyone knowing the API
  key (the `iss` of every client token) could sign. `LivekitToken.toJwt`,
  `LivekitToken.verify` and `LivekitWebhookReceiver.receive` throw
  `StateError` on an empty secret, and boot fails (not just warns) when
  `LIVEKIT_API_KEY` is set but the secret is not.
- `daravel_mysql`: `close()` drains in-flight statements before closing
  the pool (`mysql_dart` never completes callers queued for a connection
  once the pool is closed, so a graceful shutdown could hang), and the
  `connect()` probe is bounded, since `mysql_dart` opens its socket
  without a timeout.
- `daravel_teobiefy`: `LIBSODIUM_STRICT_PAYLOAD` (off by default) keeps
  clear keys sent beside `data_enc` out of the input and answers `406` to
  a clear body from a client that holds a session.
- `daravel_teobiefy` refuses a replayed request: every nonce a session
  uses is remembered (`TeobiefySessions.useNonce`, the cache's `add` for
  the session's TTL) and a body sent again is `406`, recorded only after
  its tag checked out so a forgery cannot burn a genuine nonce. A clear
  body from a client with no key is `409 SESSION_KEY_REQUIRED` before the
  handler runs (it used to run on the clear data and only the response
  was refused), and a presented session id the store does not know is
  `409` even with the legacy key, instead of a `406` the client cannot
  act on.
- `daravel_teorion` closes three holes a client's query parameters opened:
  `allowedWiths` is matched by full path (`author` no longer opens
  `?withs[]=author.posts.comments`, nor a relation the model does not
  define, which was a 500); `?visibles[]=` un-hides only attributes the
  filter lists in the new `allowedVisibles` (empty by default: a client
  could un-hide `password` hashes; `DisallowedVisibleException` in strict
  mode); and `?per_page=` / `?max_results=` are clamped to the new
  `TEORION_MAX_PER_PAGE` (`TeorionConfig.maxPerPage`, 100) with values
  below 1 meaning the default (`-1` dumped the table, `0` divided the
  paginator by zero).
- A request whose `Host`, `X-Forwarded-Host` or `X-Forwarded-Proto` header
  does not parse as a URI (`Host: [::1`, a space) is answered with `400`
  and the connection closed. `Request.fromHttpRequest` throws
  `BadRequestHttpException` for it; it used to throw `FormatException`
  out of the server's listen callback, which ended the serving isolate:
  one malformed request stopped a single-isolate server, and five within a
  minute made a supervisor exit with its crash-loop code.
- `MemoryDisk.deleteDirectory('')` (the disk of `Storage.fake()`) refuses
  the disk root with a `StorageException`, as `LocalDisk` does. It used to
  return `false`, so a test passed where the real disk throws.

## 1.13.0

Two first-party packages for a virtual classroom next to a Laravel
application join the release line: `daravel_livekit` (LiveKit's server
SDK, checked against a LiveKit server and LiveKit's PHP SDK) and
`daravel_google` (OAuth tokens in google/apiclient's JSON, service
accounts, Google Calendar events with Google Meet links), both first
published as 1.12.0. From the architecture audit of 2026-10-27: per-worker
load shedding (`HTTP_MAX_IN_FLIGHT`, `HTTP_MAX_QUEUE_DELAY`), `doctor`
notes on isolates, log level and SQLite, worker-labelled and coordinator
metrics, an operations guide and reconstructed ADRs, and benchmarks that
measure overload in an open loop. Presence channels no longer repeat or
reorder member events across broadcasting servers.

### Added

- `daravel_google` (Blueprint #49): Google for Daravel. `GoogleOAuth`
  (the consent URL with offline access, the code exchange, refresh and
  revoke), `GoogleServiceAccount` (key files and RS256 assertions per
  RFC 7523, checked byte for byte against OpenSSL, with domain-wide
  delegation), credentials that refresh a minute early with one refresh
  for concurrent calls, and `GoogleCalendar` (events with guests and
  Google Meet links: create, get, list, patch, replace, delete).
  `GoogleToken` reads and writes google/apiclient's token JSON, so a
  Laravel application and a Daravel one share a stored token.
  `withGoogle()` reads `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
  `GOOGLE_REDIRECT_URI`, `GOOGLE_APPLICATION_CREDENTIALS`,
  `GOOGLE_CALENDAR_ID` and `GOOGLE_CALENDAR_IMPERSONATE`.
- Load shedding, per worker isolate, off by default: above either limit a
  request is refused before routing with `503 Service Unavailable`,
  `Retry-After: 1` and `{"message":"Service Unavailable"}` (a body-less
  request keeps its keep-alive connection), so an overloaded worker fails
  fast instead of queueing until every client times out. `HTTP_MAX_IN_FLIGHT=N`
  (`ServeOptions.maxInFlight`, `serve --max-in-flight=N`) caps requests
  awaiting I/O at once; the slot is released after `terminate()` and an
  upgraded WebSocket holds none. `HTTP_MAX_QUEUE_DELAY=200ms`
  (`ServeOptions.maxQueueDelay`, `serve --max-queue-delay`) refuses
  requests while the worker's event loop runs that late, measured by a
  5 ms timer, the limit that sees CPU-bound or SQLite work (such a
  handler never counts as in flight). The health probes are never
  refused. Refusals are counted in `http_requests_shed_total` and logged
  at most once a second, naming the limit hit; `ServerEngine.inFlight`,
  `queueDelay` and `shedRequests` expose the numbers. `serve --watch`
  passes both options on to the server it runs and restarts.
- `dartisan new` projects (and the starter's `.env.example`) set
  `HTTP_MAX_QUEUE_DELAY=200ms`, so a new application sheds load instead of
  queueing without bound; `HTTP_MAX_IN_FLIGHT` stays commented out.
- `bench/`: scenario `11-overload` floods scenario 2's endpoint with
  `--overload-connections` (512) against a server without a limit, with
  `HTTP_MAX_IN_FLIGHT=--max-in-flight` (32), and with
  `HTTP_MAX_QUEUE_DELAY=--max-queue-delay` (50ms) added, reporting goodput,
  p99 and the share refused. The load generator counts `503`s apart from
  errors, and `--scenarios` ids now match exactly (`1` no longer selects
  `11`). `bench/public.sh` runs it `RUNS` times and reports it.
- `bench/`: `--database` takes a PostgreSQL URL as well as a SQLite path, so
  scenarios 2–4 and 11 run against PostgreSQL seeded with the same data;
  when nothing answers there the harness prints "postgres scenarios
  skipped" and exits 0. The nightly benchmark runs them against a
  PostgreSQL service container, and `public.sh` includes scenario 11 in
  its PostgreSQL runs.
- `dartisan db:install pgsql` adds `DB_POOL_SIZE=10` and
  `HTTP_MAX_IN_FLIGHT=40` (about 4 × the pool) to the PostgreSQL block of
  `.env.example`: a worker waiting on PostgreSQL does not lag, so
  `HTTP_MAX_QUEUE_DELAY` alone never sheds there, while the in-flight limit
  kept p99 at 47 ms instead of 6.2 s at 1.5 × capacity (bench scenario 12,
  4 isolates, pool 4).
- `bench/`: scenario `12-open-loop` measures load shedding where it
  applies: the capacity of scenario 2 is measured, then 1.5 times it
  (`--open-loop-factor`) arrives at a fixed rate, from clients that do not
  retry, with latency counted from each request's due time
  (`runOpenLoop`). Scenario 11's clients retry at once (a closed loop), so
  the number waiting never falls and shedding can only add the cost of its
  refusals.
- `daravel_livekit` (Blueprint #48): LiveKit's server SDK for Daravel.
  `LivekitToken` signs access tokens with LiveKit's claims and
  `VideoGrant`s, `RoomServiceClient` manages rooms and participants over
  Twirp with a 10-minute token per call carrying only its grant, and
  `LivekitWebhookReceiver` verifies webhooks (signature, expiry, issuer and
  the body's SHA-256), with no switch to skip it. `withLivekit()` reads
  `LIVEKIT_URL` / `LIVEKIT_HOST`, `LIVEKIT_API_KEY` and
  `LIVEKIT_API_SECRET` / `LIVEKIT_SECRET_KEY`. Tested against a LiveKit
  server, which accepts its join tokens, and against LiveKit's PHP SDK
  (`bench/interop/livekit.sh`).
- `dartisan doctor` gives tuning advice as `[note]` lines, a new
  `CheckStatus.notice` that never fails, not even with `--production`
  (deployments use it as a gate): one isolate on a machine with more cores,
  `LOG_LEVEL` below `warning` (a line per request at `info`), and a SQLite
  file shared by several isolates. The PostgreSQL pool check counts the pool
  the driver opens (`DB_POOL_SIZE` or `pool=` in `DB_URL`) and says
  "skipped" when the database is unreachable instead of assuming 100.
- `serve` with several isolates on a SQLite file logs one warning: SQLite
  calls are synchronous, so a worker waiting for another isolate's write
  lock blocks its event loop. `DatabaseConfig.sharesSqliteFile(isolates)`
  answers the same question.
- `/metrics` reports the coordinator's own counters,
  `coordinator_messages_total`, `coordinator_rejected_total` and
  `coordinator_in_flight`, with one isolate or under a supervisor, so a
  flood of coordinator messages shows (`rate(coordinator_messages_total[1m])`).
  `Coordinator.stats()` adds `messages`, `uptime_s` and
  `messages_per_second`. A test keeps every standard coordinator service
  synchronous.
- The README's release number is written by `tool/docs/generate.dart` and
  checked by `--check`, so it cannot fall behind the packages.
- Guide: [Operations](docs/guide/operations.md) (isolates, the database
  connection formula, load shedding, reverse-proxy connections, the
  metrics to watch, graceful shutdown), and the Database and Deployment
  guides now say plainly that SQLite is for development, tests and
  single-isolate deployments, PostgreSQL for production with several
  isolates.
- `docs/adr/`: ADR-003 (state scopes, with the rate-limit leases), ADR-004
  (supervisor and workers) and ADR-024 (Laravel's defaults for `Crypt` and
  hashing), reconstructed from the code for readers without the
  maintainer's design documents.

### Changed

- `http_requests_in_flight` and `http_requests_shed_total` carry a `worker`
  label (`daravel-worker-N`, or the isolate's name), one series per worker:
  workers share the port, which spreads connections rather than requests,
  and an uneven worker now shows. Queries that expect one series need
  `sum(...)`.

### Fixed

- With several broadcasting servers, a client joining a presence channel
  could hear `member_added` for a member its `subscription_succeeded`
  already listed, or before it: a frame relayed from another server
  arrived late. Frames now wait for `subscription_succeeded`, and each
  connection drops member events its members already reflect.

## 1.12.0

Three first-party packages share their data with a Laravel application:
`daravel_redis` (Redis and Valkey on one server, behind Sentinel or as a
Cluster: cache, tags, locks, rate limits, queues, broadcasting, checked
against Laravel 12), `daravel_permission` (roles and permissions on
spatie/laravel-permission's tables) and `daravel_teorion` (laravel-teorion's
query filters). The ORM loads specific columns of a relation without
losing the keys it matches on, a unique index refusing a row is a
`UniqueConstraintViolationException`, and `firstOrCreate` no longer fails
when two requests create the same row. Upgrade from any 1.x with
`dartisan upgrade`; the new packages are added with `dart pub add` (or
`dartisan redis:install`).

### Added

- `daravel_redis`, the eighth package (Blueprints #41 and #43): Redis and
  Valkey for the `cluster` scope, chosen in `.env` after `.withRedis()`.
  `CACHE_STORE=redis` (cache, Laravel-compatible locks, the JWT denylist),
  `CACHE_LIMITER=redis` (one Lua script per attempt),
  `QUEUE_CONNECTION=redis` (jobs that start as soon as they are pushed,
  through `BLPOP`, at least once) and `REVERB_SCALING_DRIVER=redis`
  (broadcasting servers over Pub/Sub). Its own RESP client pipelines
  commands on one connection per isolate, with command timeouts, bounded
  in-flight commands and TLS; `cache:clear` deletes only the cache's keys.
  It reaches Sentinel's master (`redis+sentinel://`, found again after a
  failover) and Redis Cluster (`redis+cluster://`: slot map, `MOVED` and
  `ASK`, keys of several slots split), offers `CACHE_STORE=tiered` (each
  isolate's memory in front of Redis, kept exact by `CLIENT TRACKING`), a
  stream queue engine with a consumer group (`QUEUE_REDIS_ENGINE=stream`),
  cached values in PHP's `serialize()` format so Laravel reads them
  (`REDIS_SERIALIZER=php`), sliding-window and GCRA rate limits, cache tags
  in Laravel 12's layout, `Redis.throttle` and `Redis.funnel` on Laravel's
  scripts and keys (so both frameworks count against one limit), sharded
  Pub/Sub that follows its slot, server-sent events that resume from a
  stream (`Redis.events('orders').since(request)`), and the `redis:ping`,
  `redis:stats`, `redis:keys-audit`, `redis:inspect` (also the MCP tool
  `redis_inspect`), `cache:prune-stale-tags` and read-only `redis:cli`
  commands. `bench/interop/redis.sh` checks locks, numbers, arrays, tags and
  throttles against Laravel 12. Tested on Redis 7 and Valkey 8, Sentinel
  failover and Cluster resharding included, in CI as well.
- `daravel_permission` (Blueprint #36): roles and permissions in the
  database on spatie/laravel-permission's five tables, so Laravel and
  Daravel share them (`bench/interop/permission.sh` checks it against
  Spatie 6). `HasRoles` on a model (`assignRole`, `syncRoles`, `hasRole`,
  `hasPermissionTo`, ...), `Role` and `Permission` with Spatie's
  exceptions, the `role`, `permission` and `role_or_permission` middleware
  with Spatie's 403 messages, a gate hook, guards, opt-in wildcards and
  super-admin role, the `permission:*` commands, and an in-memory cache
  invalidated across isolates and processes.
- `daravel_teorion` (Blueprint #33): a port of laravel-teorion 2.4 with its
  request format, so one client works against Laravel and Daravel.
  `QueryFilter<T>` declares filters (exact, like, multiLike, boolean,
  null, enum, in, date, dateRange, between, range, gt, lt, has,
  jsonContains, callback, scope, macro, with alias, default and required)
  and the allowed scopes, relations, counts, aggregates and sorts;
  `filterAndPaginate`, `findFiltered` and `filter` on any model query
  apply them, with legacy and isolated scopes, three sort formats,
  pagination, cursors, soft deletes, visibility, validation rules,
  OpenAPI parameters and the fingerprinted `QueryAudited`. Unlike the
  original it quotes `order_null_bottoms[]` (laravel-teorion writes it
  into SQL), takes `withs[]=relation:columns` only within
  `allowedWithColumns` (laravel-teorion passes any column), applies range
  filters
  from their own parameters and answers refusals with 400.
  `dartisan make:query-filter Post` writes one and registers it.
- `Blueprint.primary([...])`: primary keys over several columns, named as
  Laravel names them.
- `QueryException` and `UniqueConstraintViolationException` (Blueprint
  #45): a refused query throws them with its SQL, bindings, connection and
  the driver's error, a unique index or primary key refusal as the
  subclass (SQLite, PostgreSQL `23505`, MySQL/MariaDB `1062`, recognised by
  each driver through `QueryErrors`). Their message keeps the `?`
  placeholders, so binding values stay out of logs. `createOrFirst`, and
  `firstOrCreate` and `updateOrCreate` through it as in Laravel 12, return
  the existing row when a concurrent request created it first, in a
  savepoint inside a transaction.
- Eager loading specific columns (Blueprint #44): `with_('user:id,name')`,
  nested (`posts.comments:id,body`) and as a map key next to a constraint,
  as Laravel's colon syntax. The keys a relation matches on, the keys the
  next nested level reads and a root `select`'s foreign keys are added
  when left out (`Relation.matchColumns`, `parentColumns`); the pivot and
  intermediate columns of `BelongsToMany` and `HasManyThrough` stay
  selected and qualified.
- `Cache.tags([...])` (`TaggableCacheStore`, `TaggedCacheStore`): tagged
  entries and their flush, on the `memory` and `process` stores with
  Laravel's tag ids (`TagSetCacheStore`) and on daravel_redis's with
  Laravel's Redis layout; `file` and `database` refuse, as in Laravel.
- `dartisan redis:install [--docker]`: adds daravel_redis, `.withRedis()`,
  its commands, its `.env` keys and a Valkey (or Redis) compose service.
- MCP tools from packages: a command that is an `McpToolSource` adds its
  `McpTool`s to `mcp:serve` (write tools with `--allow-write` only).
- `Limit.slidingWindow()` and `Limit.gcra()` (`RateLimitAlgorithm`):
  rate limits without the fixed window's burst at a reset, counted by
  stores that support them (`AlgorithmRateLimitStore`, `RateCounterStore`:
  `CACHE_LIMITER=redis` with daravel_redis) and as a fixed window
  elsewhere. `throttle` passes a named limiter's algorithm on.
- `ApplicationBuilder.withCacheStore`, `withQueueDriver`,
  `withBroadcastScaling` and `withShutdown`, for driver packages; the
  `BroadcastRelay` contract; `REVERB_SCALING_DRIVER`.

### Fixed
- `firstOrCreate` and `updateOrCreate` called at once for the same row no
  longer fail with the database's unique error: the second returns the
  first's row.
- Projects from `dartisan new --path` or `--source=git` pin `dartisan_cli`
  too, so packages depending on it by name (daravel_redis,
  daravel_permission) resolve from the same source.

- `withConfig(MyConfig.fromEnv)` registered the section as a plain
  `ConfigSection`, so `Config.section<MyConfig>()`, as the configuration
  guide shows it, never found it.
- `withAuth`, `withPolicies` and `withMiddleware` kept only the last call;
  every call now applies, in order, so packages can add guards, gate hooks
  and middleware aliases next to the application's.
- With a queue connection other than `sync` and `memory`, failed jobs are
  stored in `failed_jobs`, as in Laravel, instead of in memory.

## 1.11.0

Broadcasting grows up: several servers share Echo's clients through the
database (`REVERB_SCALING_ENABLED`), cache and end-to-end encrypted
channels work as on Pusher, and one server holds 10 000 idle connections
in 189 MB with an event reaching all of them in 0.6 s. Database rate
limits take one statement per attempt and idle queue workers wake when a
job is pushed. Upgrade from any 1.x with `dartisan upgrade`; add
`CreateBroadcastingTables()` to `bootstrap/migrations.dart` before turning
scaling on.

### Added

- Cache channels: `cache-`, `private-cache-` and `presence-cache-` channels
  keep their last event for 30 minutes and send it to new subscribers (or
  `pusher:cache_miss`), as Pusher Channels does.
- End-to-end encrypted channels: with `REVERB_ENCRYPTION_MASTER_KEY_BASE64`,
  events on `private-encrypted-` channels are sealed with libsodium's
  `secretbox` under a per-channel key that `/broadcasting/auth` hands to
  admitted clients, so `Echo.encryptedPrivate` works; the same with
  `BROADCAST_CONNECTION=reverb` and `pusher`.
- `r.ws(path, handler, compress: false)` and
  `Response.webSocket(handler, compress: false)` turn permessage-deflate
  off.
- `bench/interop/connections.sh`: 10 000 idle Echo connections against the
  AOT build, with memory and fan-out time.
- Several broadcasting servers (`REVERB_SCALING_ENABLED`, Reverb's
  horizontal scaling) through the database instead of Redis:
  `CreateBroadcastingTables` stores relayed frames, channel members, server
  heartbeats and cache channels, so events, presence members (`here`
  included, which Reverb keeps per server), `member_added` / `_removed`,
  the channels API and cache channels span every server. PostgreSQL wakes
  the servers with `NOTIFY`; MySQL and MariaDB poll
  (`REVERB_SCALING_POLL`). The interop suite runs Echo against two servers.
- Idle queue workers wake when a job is pushed (`WakeableQueueDriver`):
  the database queue sends a PostgreSQL `NOTIFY` heard by workers on every
  machine, the memory queue wakes its isolate's workers, and `stop()` ends
  the wait (Review #42, PERF-02).
- `DatabaseManager.notifications(channel)` and `notify(channel, payload)` over
  PostgreSQL's `LISTEN` / `NOTIFY` (`NotifyingDriver`).

### Changed

- The Pusher endpoint runs without permessage-deflate, as Reverb's does:
  one event reaches 10 000 connections in 0.6 s instead of 7.9 s.
- A WebSocket connection no longer keeps the HTTP request (parser, headers,
  response) alive: about 18 KB per idle connection instead of 23 KB.
- `CACHE_LIMITER=database` counts an attempt with one upsert instead of
  five to seven queries (`WindowCounterStore`); blocked attempts are not
  counted, as before (Review #42, PERF-01).

## 1.10.1

Security fixes from Review #42; upgrade with `dartisan upgrade`. A JWT
revoked on one worker isolate is now refused on all of them, and
`queue:restart` and `queue:pause` reach `queue:work` processes. With
`QUEUE_CONNECTION=database`, unique jobs now keep their locks in the
`database` cache store, so that queue needs the cache tables
(`CreateCacheTable`) when it runs `ShouldBeUnique` jobs.

### Fixed

- `dartisan queue:restart`, `queue:pause` and `queue:continue` reached no
  `queue:work` process with the database queue: their signals lived in the
  memory of the command's own process. They now go to the `file` cache
  store (`QUEUE_SIGNAL_STORE=database` for workers on several machines)
  (Review #42).
- A revoked JWT stayed valid on the other worker isolates, and guards
  without a denylist could not revoke at all: `auth.jwt(...)` now uses a
  denylist in the default cache store (the `process` store when that is
  `memory`), shared by every isolate. A revoked token also stays refused
  through the verification leeway after `exp` (Review #42).
- Unique-job locks taken by the server could not be released by a separate
  `queue:work` process, so a unique job was skipped until its lock expired
  (a year without `uniqueFor`). With `QUEUE_CONNECTION=database` they now
  default to the `database` cache store (the `cache_locks` table of
  `CreateCacheTable`), and boot warns when `QUEUE_UNIQUE_LOCK_STORE` names
  a store of one process.

## 1.10.0

Broadcasting with Laravel Echo: Daravel speaks the Pusher protocol as
Laravel Reverb does, Laravel can broadcast through it and it through
Reverb. bcrypt runs in the system's C library on Linux, so a login costs
what it costs in Laravel. Upgrade from any 1.x with `dartisan upgrade`;
the `broadcast` notification channel now uses `private-App.Models.User.{id}`.

### Added

- Broadcasting with Laravel Echo (Blueprint #26): Daravel speaks the
  Pusher protocol (version 7) as Laravel Reverb does, on its HTTP port.
  `withBroadcasting(channels: ...)` with `REVERB_APP_ID`, `REVERB_APP_KEY`
  and `REVERB_APP_SECRET` serves `/app/{key}` (Echo, pusher-js),
  `/broadcasting/auth` (Laravel's channel signatures; the `channels`
  callbacks are `routes/channels.php`), and the HTTP API (`/apps/{id}/events`,
  `batch_events`, `channels`, `channel`, `users`). Public, private and
  presence channels, client events (`whisper`) and `toOthers` work, and
  connections, subscriptions and presence members are shared by every worker
  isolate through the coordinator.
- `ShouldBroadcast` events are broadcast when dispatched; `Broadcast.event`
  (with `toOthers()`, from Echo's `X-Socket-ID`) and `Broadcast.send`.
- `BROADCAST_CONNECTION`: `daravel` (this server), `reverb` (a Laravel
  Reverb or another Daravel), `pusher` (Pusher Channels), `log`, `null`.
  Laravel broadcasts through Daravel with `BROADCAST_CONNECTION=reverb`.
  Signed API requests older than ten minutes are refused.
- `bench/interop/run.sh`: `laravel-echo` and `pusher-js` against Daravel,
  Laravel 12 through Daravel, and Daravel through Laravel Reverb.

### Changed

- The `broadcast` notification channel sends through
  `BROADCAST_CONNECTION` on the notifiable's private channel,
  `private-App.Models.User.1`, as a Pusher event, so Echo's
  `.notification()` receives it. In 1.9.0 it published raw messages on
  `App.Models.User.1` for `Broadcast.pipe`.

- bcrypt is Daravel's own: on Linux it runs the system's C bcrypt
  (libxcrypt's `crypt_rn`, as PHP does), about 1.5 times as fast as before,
  so a login costs what it costs in Laravel; elsewhere (or with
  `DARAVEL_NATIVE_CRYPT=false`) a Dart implementation about 15% faster
  than `package:bcrypt`, which is no longer a dependency. Hashes are the
  same: `$2a$`, `$2b$` and `$2y$` are read, `$2y$` is written, and only the
  first 72 bytes of a password count, as in PHP (a longer password was
  refused before).
- `bench/laravel/compare.sh` cleans up after its containers and takes
  `SCENARIOS` (`SCENARIOS=6` measures only login).

## 1.9.0

Mail and notifications (with queued delivery, Laravel's markdown mail theme
and a broadcast channel), `Broadcast` across isolates, `DB_URL`,
`dartisan upgrade`, the complete Indonesian guide and a benchmark against
Laravel. Upgrade from any 1.x; `dartisan upgrade` does it from now on.

### Added

- Mail (Blueprint #13 §5.1): `Mailable` (Laravel 12's envelope, content and
  attachments), the `Mail` facade (`Mail.to(user).cc(...).send(...)`,
  `Mail.fake()` with `assertSent`, `assertNotSent`, `assertNothingSent`)
  and `MAIL_*` configuration read from Laravel's keys. A built-in SMTP
  transport handles STARTTLS, smtps and `AUTH PLAIN`/`LOGIN`, and `log` and
  `array` transports are included; `withMailTransport` adds your own.
  Messages are standard MIME (alternatives, quoted-printable, attachments,
  RFC 2047/2231). Header values with line breaks are refused, so user input
  cannot inject headers.
- Notifications (Blueprint #13 §5.2): `Notification` with `via`, `toMail`
  (`NotificationMail` or a `Mailable`) and `toDatabase`, `user.notify(...)`,
  `Notifications.send/route/of/markAsRead/unreadCount/fake`, and custom
  channels with `withNotificationChannel`. `CreateNotificationsTable()` is
  Laravel's table and rows are written as Laravel writes them, so both
  frameworks read each other's notifications.
- `make:mail` and `make:notification`.
- Queued mail and notifications: `Mail.to(...).queue(...)` and
  `.later(delay, ...)`, and `with ShouldQueue` on a mailable or a
  notification. The message, or a notification's database row, is
  prepared when it is queued and delivered by the framework's own jobs
  (`daravel:mail`, `daravel:notification`; nothing to register). Inside a
  transaction it is pushed on commit. Custom channels can implement
  `QueueableNotificationChannel`. `Mail.fake()` adds `assertQueued`,
  `assertNotQueued`, `assertNothingQueued` and `assertNothingOutgoing`.
  `daragic:export` leaves the framework's own jobs out of the DAM.
- `dartisan --version` (`-V`) prints the version: `Dartisan CLI <version>`
  outside a project, `Daravel Framework <version>` from a project's CLI.
- Translation check for the Indonesian guide (Blueprint #24): each page in
  `docs/guide/id/` records the hash of its English page, and
  `tool/docs/generate.dart --check` (a CI gate) fails when a translation is
  out of date or its headings and code blocks no longer match. Run
  `--stamp=id/<page>.md` after updating a translation. Pages without a
  translation are only listed. Every guide page now has an Indonesian
  translation, and the repository and package READMEs have a
  `README.id.md` with a language switcher, checked the same way.
- Documentation site: the EN / ID choice is remembered, and a visitor
  arriving from another site on a page in the other language is sent to
  the same page in theirs.
- `Broadcast` (`Broadcaster`): publish to a channel from any isolate and
  every worker isolate delivers to its own listeners, through the
  coordinator, without Redis. `Broadcast.pipe(socket, channels)` forwards
  channels to a WebSocket until it closes; `subscribe` gives a stream (for
  SSE). Only isolates with a listener on the channel receive a message.
- Markdown mail and the mail theme: `MailContent(markdown: ...)` renders
  in Laravel 12's default mail theme, with its styles inlined, and Laravel's
  `<x-mail::button>` and `<x-mail::panel>` components (or `mailButton`,
  `mailPanel`). `withMailTheme` changes colors, logo and footer.
  Notification mail is rendered from the markdown of Laravel's
  `notifications::email` template, with its subcopy.
- The `broadcast` notification channel: Laravel's
  `BroadcastNotificationCreated` event (`toBroadcast` or `toArray`, plus
  `id` and `type`) on the notifiable's channel (`App.Models.User.1`), with
  the same id as the database row.
- `dartisan upgrade [--check] [--to=<version>]`: sets every Daravel package
  in `pubspec.yaml` to the release (git and path packages are left alone),
  runs `dart pub upgrade` and activates the same global `dartisan`.
  `dartisan self-update` updates only the global CLI. The global
  `dartisan` runs both, so they work in projects whose CLI predates them.
- `bench/laravel/compare.sh`: Daravel against Laravel 12 (Octane on
  FrankenPHP, and classic) on the same cores, database and load generator,
  with the same endpoints. `bench.dart --external=name:port` measures any
  running server with the scenarios.

- `DB_URL`, as in Laravel 12: one URL sets the database
  (`postgres://user:pass@host:5432/app?sslmode=require`) and is merged into
  the connections the way Laravel's `ConfigurationUrlParser` merges it.
  The scheme picks the driver (`postgres` → `pgsql`, `mysql2` → `mysql`),
  parts the URL gives replace the `DB_*` values and the rest stay, and the
  query string adds options. A `.env` written for Laravel with `DB_URL` now
  configures Daravel the same way. `ConnectionConfig.withUrl` is the merge.

### Changed

- `mcp:install` in a DDEV project (`.ddev/config.yaml`) registers
  `ddev dartisan mcp:serve`, which runs in the web container where the
  packages are resolved. It adds `.ddev/commands/web/dartisan` when
  missing and replaces an entry still at the host default
  (`dart run bin/dartisan.dart mcp:serve`), which cannot work there.
- The release workflow skips packages whose version is already on pub.dev,
  so re-running it finishes a release that was partly published by hand.

### Fixed

- PostgreSQL: `double.infinity`, `-infinity` and `NaN` bindings are sent as
  typed `float8`. `package:postgres` sent them as the SQL text `'infinity'`,
  quotes included, which PostgreSQL rejected.

## 1.8.1

A fix for clients generated with `client:flutter --state`. Upgrade from
any 1.x.

### Fixed

- `client:flutter --state`: the generated `providers.dart`, `blocs.dart` and
  `cubits.dart` imported `runtime.dart` even when no route used a runtime
  type (no paginator, no upload, as in a new project's auth routes). The
  resulting `unused_import` warning failed `dart analyze --fatal-infos`.

## 1.8.0

Database driver packages (`daravel_sqlite`, `daravel_postgres`),
`db:install`, `db:transfer`, extra connections, and the Flutter client's
state adapters and watch mode. Upgrade from any 1.x. One behaviour changes:
transactions are per connection, as in Laravel (see Fixed).

### Added

- `daravel_sqlite` and `daravel_postgres` (Blueprint #31): driver packages
  with `.withSqlite()` / `.withPostgres()`, re-exporting the drivers that
  stay built into 1.x. Depending on them now means 2.0, where the core no
  longer depends on any database client, needs no change.
- `dartisan db:install <driver>`: adds the driver package, registers it in
  `bootstrap/app.dart` and documents its keys in `.env.example`.
- `dartisan db:transfer --from --to`: copies an application's data to
  another database (connection names or URLs). The target is migrated
  first, and the copy is one transaction, parents first. Values are adapted
  to the target, PostgreSQL foreign keys are deferred during the copy and
  its sequences continue after the copied ids.
- `withDatabaseConnection(name, (env) => ...)` adds connections with their
  own settings, and `ConnectionConfig.fromUrl` reads `pgsql://`,
  `mysql://`, `mariadb://` and `sqlite:` URLs. `SqliteDriver.fromConfig`,
  `PostgresDriver.fromConfig` and `DatabaseManager.forConnection` are new
  too.

- `client:flutter --state=riverpod,bloc,cubit`: state adapters on the pure
  Dart `riverpod`/`bloc` packages (used by `flutter_riverpod`/`flutter_bloc`).
  Riverpod gets a client provider and a `FutureProvider.autoDispose` family
  per `GET` route, with record arguments for several parameters. Bloc and
  Cubit get one class per route on a shared `RemoteState<T>` (idle,
  loading, data, error, with the 422 `validation`).
- `client:flutter --watch`: regenerates the client when routes, requests,
  resources or `.env` change, in a fresh process per run.

### Changed

- The starter and `dartisan new` projects declare their auth routes:
  `.validates(RegisterRequest/LoginRequest)` and `.returns(...)` on
  register, login, me and logout. The controllers read
  `request.validated()`, so the input is still validated once. The
  OpenAPI document and `client:flutter` now type these routes:
  `api.auth.login(email:, password:)` returns an `AuthToken` with a `User`.
- `client:flutter`: a schema's `title` names its model, so a schema reused
  inside another response is one class; `.returns(..., status: 204)` is
  `Future<void>`.

### Fixed

- Transactions are per connection, as in Laravel. A query on another
  connection inside `DB.transaction` (`DB.table(t, connection: 'other')`)
  ran inside the transaction of the default connection, on the wrong
  database. A `DB.transaction(..., connection: 'other')` inside one became a
  savepoint of it. Both now use their own connection and transaction.
- `client:flutter`: a route with an optional path parameter and declared
  input generated code that did not compile (the input was dropped). The
  optional parameter is now named, next to the input.

## 1.7.0

A typed Dart/Flutter client generated from the routes. Upgrade from any
1.x; WebSocket routes no longer appear in the OpenAPI document.

### Fixed

- The `daily` log channel could keep one file more than
  `LOG_DAILY_DAYS`: today's file is opened asynchronously, so pruning
  counted it only when it already existed. It now always keeps today plus
  the newest `days - 1` older files.

### Added

- `dartisan client:flutter`: generates a typed Dart/Flutter client package
  (plain Dart on `package:http`) from the routes. It produces methods per
  route name, models from `.returns()` schemas, Laravel's paginators,
  `ValidationException` for 422 responses, a bearer `TokenStore`,
  server-sent events and WebSocket URLs. Input classes check the server's
  own rules on the device, with the messages resolved by the server's
  translator, so a form shows exactly what a 422 would say. Rules that need
  the server (`unique`, closures, files, ...) are listed instead of guessed.
- `RouteEntry.isWebSocket`. WebSocket routes are left out of the OpenAPI
  document.

## 1.6.0

Real-time responses: server-sent events and WebSocket routes. Upgrade from
any 1.x; nothing existing changes behaviour except that unsized streamed
responses are now written unbuffered.

### Added

- Server-sent events: `Response.sse(stream)` and `SseEvent` (Laravel's
  `response()->eventStream()` and `StreamedEvent`, with the same frames and
  `</stream>` end event). Adds a heartbeat comment while idle, which also
  detects closed clients, and ends open streams on shutdown.
- WebSockets: `router.ws(path, (socket, request) {...})` upgrades after the
  route's middleware, runs the handler in the request's scope, answers plain
  requests with `426`, and closes open sockets with `1001` on shutdown
  (`ServerEngine.openWebSockets`).
- `DrainSignal` (bound in the container): completes when the application
  starts draining, for long-lived work that should end on shutdown.

### Changed

- A `Response.stream` without a content length is written unbuffered, so
  each chunk goes out as it is produced.

## 1.5.1

A fix for JSON numbers outside the double range. Upgrade from any 1.x.

### Fixed

- A JSON body with a number outside the double range (`{"n": 1e309}`,
  which decodes to Infinity) is now `400 Malformed JSON body: Number out of
  range`. Before, `numeric` accepted it; a response echoing it was a 500,
  and on SQLite a stored value made every later read of that row a 500.
  PostgreSQL and MySQL rejected the insert (a 500). Laravel behaves as
  Daravel did (`is_numeric(INF)` is true, `json_encode` fails); this is a
  deliberate, safer difference. Reported in the security audit
  (Blueprint #23).

## 1.5.0

The application model export for `daragic`, test suites over a real
socket, and a fix for a shared rate limit that could let one request too
many through; all backwards compatible.

### Added

- `TestTransport.socket` for `TestClient` (or `DARAVEL_TEST_TRANSPORT=socket`
  for a whole suite): requests go through a real `ServerEngine` on a
  loopback port and `HttpClient`, so `dart:io`'s behaviour is tested too.
  The application sees the same requests as in process; `actingAs` works
  through `ServerEngine.prepare`, a new per-request hook. CI runs the core,
  toolkit and starter suites both ways on Linux, macOS and Windows.
- `dartisan daragic:export [--out] [--only]`: the application's structure as
  a DAM (BLUEPRINT_DARAGIC §5, §7) in `dam.json` plus `daragic.lock`
  (hashes per section and entity): routes (Laravel-style URIs, actions,
  middleware, unanchored `where` patterns, validation as DSL and structured
  rules, responses), models with relations, migrations with batches,
  schema, schedule, jobs, feature flags, translations, middleware and
  `.env.example` keys without secrets. Deterministic and offline-safe (no
  database: the schema is marked unavailable). Method bodies are listed in
  `report.unsupported` until the Dialect IR extractor exists.
- `TouchableCacheStore.touch(key, ttl)` (Laravel's `Cache::touch`): change
  how long a key lives without rewriting its value; the memory, file and
  database stores implement it.

### Fixed

- A shared rate limit (`CACHE_LIMITER`, `CacheRateLimitStore`) could let one
  request too many through under concurrency (seen in CI on MariaDB: 11 of
  a limit of 10). When a request found the counter just created by another
  one and incremented it to 1, it reset the counter to 1 as Laravel's
  `RateLimiter::hit()` does, losing the other request's hit. It now only
  gives the counter a lifetime (`touch`), so every hit counts. Covered by a
  test that forces that interleaving.

## 1.4.1

A fix for response headers that piled up across requests on a running
server. Upgrade from any 1.x.

### Fixed

- Response headers piled up across requests on a real server
  (`x-content-type-options: nosniff, nosniff, ...`,
  `x-frame-options: SAMEORIGIN, DENY, DENY, ...`): `dart:io` shares the
  value lists of the server's default headers with every response, and
  writing a header appended to them. The server now starts without
  `dart:io`'s defaults (Daravel's middleware sets these headers; JSON
  responses no longer get `X-Frame-Options: SAMEORIGIN` or the obsolete
  `X-XSS-Protection`), and `Response.writeTo` replaces header values instead
  of appending. Covered by a socket test.

## 1.4.0

Laravel's everyday web layer: a live API reference, localization, HTTP
caching and compression, feature flags shared with Pennant, and hot SQLite
backups; all backwards compatible.

### Added

- Live API reference (Laravel Scramble, FastAPI's `/docs`): with
  `APP_ENV=local`, `GET /docs/api` serves an interactive Scalar page of
  every route and `GET /docs/api.json` its OpenAPI 3.1 document.
  `API_DOCS` turns it on or off, `API_DOCS_PATH` moves it, and the starter's
  welcome page links to it. `buildOpenApi` moved to `package:daravel`
  (`package:dartisan_cli` still exports it).
- Localization (Laravel's translator): `trans()` (Laravel's `__()`),
  `transChoice()`, the `Lang` facade, `App.locale`/`App.setLocale()` per
  request, job or command, `ApplicationBuilder.withTranslations` and
  `lang/<locale>.json` files, `APP_FALLBACK_LOCALE`, and
  `SetLocaleMiddleware` (`?lang=` and `Accept-Language`). Placeholders and
  plural selection match Laravel, with its plural rules for 280 locales
  (tested against Laravel 12's own output). Validation messages follow the
  current locale.
- `cache.headers` middleware (Laravel's `SetCacheHeaders`): `Cache-Control`,
  `ETag` and `Last-Modified` from `public;max_age=3600;etag`-style options,
  written as Laravel writes them, and `304 Not Modified` for
  `If-None-Match`/`If-Modified-Since`.
- `CompressResponseMiddleware`: gzip for clients that accept it (text,
  JSON, XML, SVG, JavaScript bodies of at least 1 KB; strong ETags become
  weak).

- Feature flags (Laravel Pennant): `Feature.define`, `active`, `value`,
  `forScope`, `activate`/`deactivate`, `forget`, `activateForEveryone`,
  `purge`, and the `feature:a,b` middleware (400 when inactive). Values
  live in Pennant's `features` table (`CreateFeaturesTable`, scopes
  serialized as `App\Models\User|1`), so a Laravel application on the same
  database shares them; `PENNANT_STORE=array` keeps them in memory (the
  default in testing). Tested on SQLite, PostgreSQL and MySQL/MariaDB.
- `dartisan db:backup [--output] [--keep=N]`: a hot backup of the SQLite
  database (`VACUUM INTO`, consistent while the server writes, checked with
  `PRAGMA integrity_check`, never overwriting) into `storage/backups`;
  `--keep` prunes older backups. On PostgreSQL and MySQL it points to
  `pg_dump` / `mysqldump`.

### Fixed

- A `HEAD` response is stripped after the global middleware, not before:
  it now carries the same headers a `GET` would (with compression, the
  compressed `Content-Length`), and error responses to `HEAD` lose their
  body too.

## 1.3.0

A model registry with `model:show`, Laravel Boost's tools in `mcp:serve`,
the scheduler's default zone, two new lints, and a fix for `UTC` in
`timezone()`; all backwards compatible.

### Added

- `SCHEDULE_TIMEZONE` (Laravel's `app.schedule_timezone`): the zone of
  scheduled tasks that do not name their own. Unlike Laravel there is no
  fallback to `APP_TIMEZONE` in 1.x, so upgrading never moves a schedule;
  `dartisan doctor` warns when `APP_TIMEZONE` is not UTC and
  `SCHEDULE_TIMEZONE` is empty. `schedule:list --timezone=<zone>` shows the
  next runs in that zone.
- Model registry: `bootstrap/models.dart` lists the application's models
  and `ApplicationBuilder.withModels` registers them (`ModelRegistry`,
  `describeModel`). `dartisan new` and the starter include it, and
  `make:model` adds new models to it when the file exists.
- `dartisan model:show <Model> [--json]` (Laravel 11): table, attributes
  with type, cast, fillable and hidden flags, and relations with their
  keys.
- `mcp:serve` tools (Laravel Boost's counterparts):
  - `models`: the registered models and their relations, or one model in
    detail.
  - `db_query`: one `SELECT`/`WITH`/`EXPLAIN` statement in a transaction
    that is always rolled back, read-only in the database on SQLite and
    PostgreSQL.
  - `read_logs` and `last_error`: the daily log files.
- `dartisan mcp:install [--guidelines=AGENTS.md] [--force]` (Laravel's
  `boost:install`) and `dartisan new --mcp`: register the server in
  `.mcp.json`, keeping other servers, and write the Daravel guidelines
  between markers that later runs refresh.
- `dartisan lint` checks `lib/app/models` against `bootstrap/models.dart`,
  only in projects that have the file (older projects are unaffected).
- Lint `invalid_timezone`: zone names passed to `.timezone('...')` must be
  IANA zones (suggests the right case, `asia/jakarta` → `Asia/Jakarta`).
- `docs_search` takes `locale: "id"` to search the Indonesian guide pages
  as well.
- `dartisan build --docker` writes a Dockerfile without the SQLite library
  when `DB_CONNECTION` is not `sqlite` (as `build --no-sqlite`).

### Fixed

- `ScheduledTask.timezone('UTC')` (and other alias names PHP accepts, such
  as `GMT` or `US/Eastern`) threw: the bundled zone data now includes them
  (about 0.2 MB more).

## 1.2.0

Laravel's everyday conveniences, scheduler time zones, smaller bundles and
project context for AI agents, all backwards compatible.

### Added

- `dartisan build --no-sqlite`: a bundle without the SQLite library for
  PostgreSQL and MySQL applications (about 1.7 MB smaller). It applies
  `package:sqlite3`'s `source: system` only for the build, in the workspace
  root's pubspec for a workspace member, and restores the file; it refuses
  when `DB_CONNECTION` is `sqlite` unless `--force`. A server that opens
  SQLite without the library says what is missing.
- Scheduler: `ScheduledTask.timezone()` takes an IANA zone name
  (`'Asia/Jakarta'`, `'America/New_York'`) as well as a fixed `Duration`.
  Daylight saving time follows Laravel (checked against cron-expression on
  PHP): a skipped time runs that much later, a repeated time runs twice.
  `schedule:list` shows each task's zone. Adds `package:timezone` (about
  0.3 MB of zone data in the binary).
- `dartisan mcp:serve`: a Model Context Protocol server on stdio for AI
  coding agents, bound to the project: `about`, `routes` (rules, request
  schema, response, action), `schema`, `conventions` and `docs_search` over
  the guide of the installed version. Read-only by default; `--allow-write`
  adds `run_command`, which refuses long-running commands and, in
  production, destructive ones.
- `dartisan doctor` warns when the pubspec loads SQLite from the OS
  (`source: system`) while the database is SQLite.

- Dependency injection without boilerplate: `ApplicationBuilder.withBindings`
  registers services without a provider class, calling the container
  (`c()`) resolves the type each argument needs, and `inject<T>()` /
  `maybeInject<T>()` (Laravel's `resolve()`) keep defaults mockable.
- Fluent helpers: `Str` methods chain on strings
  (`title.after(':').squish().slug()`, `isBlank` on `String?`); durations
  (`10.minutes`, `7.days.fromNow`) and Carbon-style dates (`isPast`,
  `startOfDay`, `diffForHumans()` in English and Indonesian, on `Clock`);
  Laravel's `Number` (`format`, `percentage`, `currency`, `fileSize`,
  `abbreviate`, `forHumans`, `ordinal`) with intl's output for `en` and
  `id`.
- Calendar math as Carbon: `addMonths`/`addYears` (overflowing) and their
  `NoOverflow` forms, `startOf`/`endOf` week (Monday), month and year,
  `daysInMonth`, `isWeekend`, `isSameDay`, `isBetween`.
- Laravel 11 date shortcuts on queries: `wherePast`, `whereFuture`,
  `whereNowOrPast`, `whereNowOrFuture`, `whereToday`, `whereBeforeToday`,
  `whereTodayOrBefore`, `whereAfterToday`, `whereTodayOrAfter` and their
  `orWhere` forms (on `Clock`); `whereYear`/`whereMonth`/`whereDay` on model
  queries.
- `DB.whenQueryingForLongerThan` (total query time per request, job or
  command, as Laravel), `DB.totalQueryDuration`, and `DB.withQueryCount`
  for N+1 assertions.
- `Context` (Laravel 11): per-request data added to log records and carried
  into the jobs it dispatches, with hidden entries that are carried but not
  logged.
- `package:daravel/html.dart`: a typed HTML builder for pages, escaped by
  default (`raw()` for trusted markup); a node returned from a handler is
  sent as HTML.

## 1.1.0

Polymorphic relations and safer concurrency, all backwards compatible. The
fixes matter most for applications running several isolates or machines:
concurrent nested transactions, cache counters and shared rate limits no
longer lose work.

### Added

- `request.queryInt`, `queryDouble`, `queryBool` and `queryString`: typed
  query parameters without `await` (dot notation, input transformers
  applied, converted like `integer()`/`boolean()`).
- `RuleBuilder`: rule objects chain (`Rules.required().email().max(255)`)
  and validate, report and document exactly like the matching string.
- `daravel_lints`: `invalid_validation_rule` reports unknown rule names and
  missing or malformed arguments in rule strings (`.rules`, `.validate`,
  `Validator`, `FormRequest.rules`).
- `CACHE_PROCESS_L1_TTL`: the `process` store can keep values in each
  worker isolate for a short time, saving coordinator round trips for hot
  keys (off by default; misses, counters and locks are never cached).
- `CACHE_LIMITER` (Laravel's `cache.limiter`): rate limits counted in a
  cache store through `CacheRateLimitStore`; with `database`, every machine
  sharing the database shares the limits.
- Polymorphic relations, stored as Laravel stores them: `MorphOne`,
  `MorphMany`, `MorphTo` (one query per stored type when eager loading,
  nested relations per type, `associate`/`dissociate`, `touches`),
  `MorphToMany` and `MorphedByMany` (pivot `attach`/`detach`/`sync` scoped
  to the type). `Relation.morphMap`, `enforceMorphMap` and `morphClassOf`
  (Laravel's `getMorphClass`; Sanctum's `tokenable_type` follows it).
  `whereHasMorph`, `whereDoesntHaveMorph` and their `orWhere*` forms;
  `whereHas` on a `MorphTo` checks every type the relation lists.
- Nested existence queries: `whereHas('posts.comments')`, `orWhereHas`,
  `has`, `whereDoesntHave`, `doesntHave`, `withWhereHas` at any depth, and
  the new `orWhereDoesntHave`.
- Schema: `morphs`, `nullableMorphs`, `uuidMorphs`, `nullableUuidMorphs`,
  `ulidMorphs` and `nullableUlidMorphs`, with Laravel's composite index.
- `HasOneThrough`.
- Relation aggregates: `withSum`, `withAvg`, `withMin`, `withMax` and
  `withExists` (a `bool`), named as in Laravel (`orders_sum_total`), and
  `'relation as name'` aliases for all of them and `withCount`.
- `QueryBuilder.selectSub` (a subquery in the select list).
- `Relation.existenceQuery` (the subquery for `whereHas` against an aliased
  parent table); custom relations keep working through `correlated`.

- `daravel_lints`: `unawaited_in_db_transaction` flags queries started
  inside `DB.transaction` without `await`, including `unawaited(...)` and
  `.ignore()`.

### Fixed

- Database cache store: `increment`/`decrement` from several connections
  at once lost updates (a read then a write; 40 concurrent increments
  counted 12 on PostgreSQL). It is now a compare-and-swap retried on
  conflict, atomic on SQLite, PostgreSQL and MySQL.
- Transactions: nested transactions started together inside one
  (`Future.wait([DB.transaction(...), DB.transaction(...)])`) shared a
  savepoint name and interleaved, so one failing could roll back the
  other's committed work (SQLite, PostgreSQL and MySQL). Sibling savepoints
  now run one after another, queries of the outer level wait for an open
  savepoint, and a query that runs after its transaction has finished (a
  missing `await`) throws a `StateError` instead of running outside it.
- `whereHas`, `whereDoesntHave` and `withCount` on a relation to the same
  model (`Category.children`, users following users) compared the inner
  table with itself. The inner table is now aliased, as Laravel's
  `laravel_reserved_N`.
- PostgreSQL: `withCount` with a constraint, and `whereNot` with bindings,
  sent their subquery with misnumbered placeholders (`$1` inside a raw
  fragment), so the statement failed. Both now compile in the same pass as
  the outer query.

- Verifying an argon2id hash with several lanes (`p=4`, as libargon2 and
  PHP can write them) could hang when many isolates were busy: the pure
  Dart implementation spawned one helper isolate per lane from inside the
  hashing isolate. Lanes are now computed in the hashing isolate.

## 1.0.0

The first stable release. The Dart API now follows SemVer, `1.x` is the
supported release line, and MySQL/MariaDB join SQLite and PostgreSQL.

### Added

- File uploads: `multipart/form-data` bodies stream to temporary files as
  `UploadedFile` (`request.file`, `hasFile`, `store`, `storeAs`, `hashName`,
  `UploadedFile.fake`), with Laravel 12's `file`, `image`, `mimes`,
  `mimetypes`, `extensions` rules and kilobyte sizes. Types are detected from
  the content, never the name; PHP files are refused. `TestClient` and
  `Request.fake` take `files:`, and OpenAPI documents such routes as
  `multipart/form-data`.
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
