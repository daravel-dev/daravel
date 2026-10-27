# Changelog

All notable changes to the Daravel workspace (`daravel`, `daravel_test`,
`daravel_lints`, `daravel_mysql`, `daravel_redis`, `daravel_sqlite`,
`daravel_postgres`, `dartisan_cli`). Versions follow SemVer:
breaking changes to the Dart API wait for a new major version, and
Laravel-facing formats change only to match Laravel more closely.

## Unreleased

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
  into SQL), refuses `withs[]=relation:columns`, applies range filters
  from their own parameters and answers refusals with 400.
  `dartisan make:query-filter Post` writes one and registers it.
- `Blueprint.primary([...])`: primary keys over several columns, named as
  Laravel names them.
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
