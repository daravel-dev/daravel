# Changelog

## Unreleased

- Added a WebSocket frame limit: `router.ws(..., maxPayloadBytes:)` and `Response.webSocket(maxPayloadBytes:)` (1 MiB, `Response.defaultWebSocketMaxPayloadBytes`); a larger frame fails the connection as it arrives. `dart:io` sets no limit of its own, so one client could make a worker buffer a frame of any size. The Pusher server caps frames at `REVERB_APP_MAX_MESSAGE_SIZE` plus 1 KiB.
- Added `HTTP_MAX_BODY` (`ServeOptions.maxBodyBytes`, 50 MiB, `0` for none): the body limit every request served by the engine starts with, so an application without `BodyLimitsMiddleware` never buffers an unbounded body.
- Added `DB_CONNECT_TIMEOUT` and `DB_QUERY_TIMEOUT` (seconds, `0` for none; `connect_timeout` / `query_timeout` connection options, `PostgresDriver.timeoutOption`): the PostgreSQL statement timeout was a fixed 30 s, so a long `CREATE INDEX` in a migration was cancelled.
- Fixed: PostgreSQL closes its pool when the `SELECT 1` probe fails after the connection opened (each retry leaked a backend), and `listen()` closes the dedicated connection when the listener cancelled during the handshake (it lived until process exit).
- Changed: `HmacJwtKey` (so `JwtCodec.hs256`) refuses an empty secret with `ArgumentError`; HMAC over an empty key signs and verifies like any other, so a secret that was never set accepted tokens anyone could mint.
- Added `ConnectionException.isTimeout`: true when the request was sent and the answer did not come in time (it may have been processed), false when the connection was refused or reset.
- Fixed: `DB.transaction(attempts: n)` no longer re-runs a committed body when an after-commit callback fails with a retryable error; the callbacks run outside the retry.
- Fixed: a SQLite connection whose setup fails after the file is opened (not a database, stays busy) closes its handle instead of leaking it with the file locked.
- Fixed: `MemoryStore` sweeps expired, unreleased locks once there are `maxEntries` of them (`lockCount`); `ProcessRateLimitStore` sweeps the state of keys it no longer limits once `maxKeys` (10 000) are tracked (`trackedKeys`). Both only grew before.
- Fixed: a worker isolate that exits takes its presence-channel members and broadcast ports with it (`WorkerAwareService`, `Coordinator.forgetWorker`; `join` and `subscribe` carry `worker`); they used to stay for ever.
- Fixed: the supervisor kills a worker that misses `readyTimeout` (it used to keep booting and serve untracked next to its replacement), `stop()` returns at once when every worker is already gone, a respawn finishing during a drain is drained, and an inbox message with an unknown worker index is dropped rather than thrown on the main isolate.
- Fixed: a coordinator answer that cannot be sent to a worker is a `CoordinatorException` for that call instead of an uncaught error on the supervisor's main isolate; `RemoteCoordinatorChannel.call` after `close()` fails at once.
- Fixed: a request whose `Host`, `X-Forwarded-Host` or `X-Forwarded-Proto` header does not parse as a URI is answered with `400` (`Request.fromHttpRequest` throws `BadRequestHttpException`); the `FormatException` used to escape the server's listen callback and end the serving isolate.

## 1.13.0

- Added load shedding per worker: `HTTP_MAX_IN_FLIGHT` (`ServeOptions.maxInFlight`) and `HTTP_MAX_QUEUE_DELAY` (`ServeOptions.maxQueueDelay`) refuse a request before routing with `503`, `Retry-After: 1` and `{"message":"Service Unavailable"}`; the health probes are never refused; `ServerEngine.inFlight`, `queueDelay`, `shedRequests` and `http_requests_shed_total`.
- Added `coordinator_messages_total`, `coordinator_rejected_total` and `coordinator_in_flight` on `/metrics`, and `messages`, `uptime_s` and `messages_per_second` in `Coordinator.stats()`.
- Added `DatabaseConfig.sharesSqliteFile(isolates)`; `serve` with several isolates on a SQLite file logs one warning.
- Changed: `http_requests_in_flight` and `http_requests_shed_total` carry a `worker` label (one series per worker isolate).
- Fixed presence channels across broadcasting servers: no `member_added` for a member `subscription_succeeded` already listed, and no member event before it.

## 1.12.0

- Added `Cache.tags([...])` (`TaggableCacheStore`, `TaggedCacheStore`, `TagSetCacheStore`) on the `memory` and `process` stores; `file` and `database` refuse, as in Laravel.
- Added `Limit.slidingWindow()` and `Limit.gcra()` (`RateLimitAlgorithm`, `AlgorithmRateLimitStore`, `RateCounterStore`), counted by stores that support them and as a fixed window elsewhere.
- Added eager loading specific columns: `with_('user:id,name')`, nested and as a map key; the keys a relation matches on, those the next nested level reads and a root `select`'s foreign keys are added (`Relation.matchColumns`, `parentColumns`).
- Added `QueryException` and `UniqueConstraintViolationException` (`QueryErrors`, `QueryExceptionExecutor`), whose message keeps the `?` placeholders, and `createOrFirst`.
- Fixed: `firstOrCreate` and `updateOrCreate` called at once for the same row no longer fail with the database's unique error.

- Added `ApplicationBuilder.withCacheStore`, `withQueueDriver`, `withBroadcastScaling` and `withShutdown`, the `BroadcastRelay` contract and `REVERB_SCALING_DRIVER`, for driver packages such as `daravel_redis`.
- Added `Blueprint.primary([...])` (composite primary keys).
- Changed: `withAuth`, `withPolicies` and `withMiddleware` apply every call, in order, instead of keeping the last.
- Fixed: `withConfig` registers a section under its own type, so `Config.section<T>()` finds it.
- Changed: `withHealthChecks` keeps the default checks setting unless `defaults:` is given.

## 1.11.0

- Added cache channels (`cache-`, `private-cache-`, `presence-cache-`) and end-to-end encrypted `private-encrypted-` channels (`REVERB_ENCRYPTION_MASTER_KEY_BASE64`, `Echo.encryptedPrivate`).
- Added `compress:` to `Router.ws` and `Response.webSocket`; the Pusher endpoint runs without permessage-deflate.
- Changed: a WebSocket connection no longer keeps its HTTP request alive (`Request.detachBody`).
- Added several broadcasting servers through the database (`REVERB_SCALING_ENABLED`, `CreateBroadcastingTables`, `DatabaseChannelState`, `DatabaseBroadcastRelay`).
- Added `WakeableQueueDriver`: idle workers wake on a push (PostgreSQL `NOTIFY`, the memory queue) and on `stop()`.
- Added `DatabaseManager.notifications` / `notify` and `NotifyingDriver` (PostgreSQL `LISTEN` / `NOTIFY`).
- Changed: `CACHE_LIMITER=database` counts an attempt with one upsert (`WindowCounterStore`).

## 1.10.1

- Fixed: `queue:restart` / `queue:pause` reach `queue:work` processes with the database queue (`QUEUE_SIGNAL_STORE`, the `file` store by default).
- Fixed: `auth.jwt` guards get a denylist shared by every isolate (`CacheJwtDenylist`), and revoked tokens stay refused through the leeway.
- Fixed: with the database queue, unique-job locks default to the `database` cache store, so `queue:work` processes release them.

## 1.10.0

- Added broadcasting with Laravel Echo: the Pusher protocol as Laravel Reverb (`withBroadcasting`, `ChannelRegistry`, `/broadcasting/auth`, the HTTP API), `ShouldBroadcast`, `Broadcast.event` / `send`, and `BROADCAST_CONNECTION` (`daravel`, `reverb`, `pusher`, `log`, `null`).
- Changed: the `broadcast` notification channel sends Laravel's `BroadcastNotificationCreated` on `private-App.Models.User.{id}` through `BROADCAST_CONNECTION`.
- Changed: bcrypt runs in libxcrypt on Linux (about 1.5 times as fast) and in a faster Dart implementation elsewhere; `package:bcrypt` is no longer a dependency. Passwords longer than 72 bytes are cut at 72 bytes, as PHP does.

## 1.9.0

- Added mail (`Mailable`, `Mail`, SMTP, `log` and `array` transports, `MailFake`), with queued delivery and markdown mail in Laravel 12's default theme (`MailContent(markdown:)`, `mailButton`, `mailPanel`, `withMailTheme`).
- Added notifications: `Notification`, `Notifications`, the `mail`, `database` and `broadcast` channels, `CreateNotificationsTable`, `ShouldQueue` notifications and `NotificationFake`.
- Added `Broadcast` / `Broadcaster`: publish to a channel and every worker isolate delivers to its listeners, through the coordinator; `Broadcast.pipe` for WebSockets.
- Added `DB_URL` (`ConnectionConfig.withUrl`), merged as Laravel 12's `ConfigurationUrlParser` does.
- Fixed: PostgreSQL rejected `double.infinity`, `-infinity` and `NaN` bindings.

## 1.8.1

- Version aligned with Daravel 1.8.1; no changes.

## 1.8.0

- Added `ConnectionConfig.fromUrl`, `ApplicationBuilder.withDatabaseConnection`, `DatabaseManager.forConnection`, `SqliteDriver.fromConfig` and `PostgresDriver.fromConfig`.
- Fixed: transactions are per connection. A query on another connection inside `DB.transaction` ran in the default connection's transaction (on the wrong database), and a transaction on another connection became a savepoint of it.

## 1.7.0

- Added `RouteEntry.isWebSocket` (set by `router.ws`); WebSocket routes are left out of the OpenAPI document.
- Fixed: the daily log handler could keep one file more than `days` (today's file, opened asynchronously, was only counted when it already existed).

## 1.6.0

- Added `Response.sse` and `SseEvent` (Laravel's `response()->eventStream()` frames and `</stream>` end event), with an idle heartbeat that also detects closed clients, ending on shutdown.
- Added `router.ws` and `Response.webSocket`: upgrade after the route's middleware, handler in the request scope, `426` for plain requests, `1001` on shutdown.
- Added `DrainSignal`, completed when the application starts draining.
- Unsized `Response.stream` bodies are written unbuffered.

## 1.5.1

- Fixed: a JSON body number outside the double range (`1e309`) is `400 Malformed JSON body: Number out of range` instead of decoding to Infinity (a 500 when echoed, and on SQLite a stored value that broke every later read).

## 1.5.0

- `TouchableCacheStore.touch(key, ttl)` (Laravel's `Cache::touch`) on the memory, file and database stores.
- `ServerEngine.prepare`: a per-request hook inside the request scope.
- `MiddlewareRegistry.groupEntries`, `Translator.lines` / `jsonLines` (read-only).
- Fixed: a shared rate limit (`CacheRateLimitStore`) could let one request too many through under concurrency.

## 1.4.1

- Fixed: response headers piled up across requests on a real server (`x-content-type-options: nosniff, nosniff, ...`), because `dart:io` shares its default header lists with every response. The server starts without `dart:io`'s defaults and `Response.writeTo` replaces header values.

## 1.4.0

- Live API reference at `/docs/api` (Scalar) and `/docs/api.json` in local environments (`API_DOCS`, `API_DOCS_PATH`); `buildOpenApi` moved here from `dartisan_cli`.
- Localization: `trans`, `transChoice`, `Lang`, `App.locale`/`App.setLocale` per scope, `withTranslations`, `lang/<locale>.json`, `APP_FALLBACK_LOCALE`, `SetLocaleMiddleware`; validation messages follow the current locale.
- `cache.headers` middleware (ETag, `304`) and `CompressResponseMiddleware` (gzip).
- Feature flags (`Feature`, `FeatureManager`, `feature:` middleware, `CreateFeaturesTable`) in Laravel Pennant's storage format.
- Fixed: `HEAD` responses are stripped after the global middleware.

## 1.3.0

- Model registry: `ApplicationBuilder.withModels`, `ModelRegistry`, `describeModel` (read by `dartisan model:show` and `mcp:serve`).
- `SCHEDULE_TIMEZONE` (Laravel's `app.schedule_timezone`) as the default zone of scheduled tasks; `ScheduledTask.wallTime`.
- Fixed: `ScheduledTask.timezone('UTC')` and other alias zone names (`GMT`, `US/Eastern`) threw.

## 1.2.0

- `Application.withBindings`, `Container.call` shorthand, `inject<T>()`/`maybeInject<T>()`.
- Fluent `String`/`String?` helpers, `10.minutes`/`7.days.fromNow`, Carbon-style dates (`diffForHumans` in `en`/`id`) and calendar math (`addMonths` overflowing as Carbon, `NoOverflow` forms, week/month/year boundaries); `Number` (`format`, `currency`, `fileSize`, `abbreviate`, `forHumans`, `ordinal`).
- Query shortcuts `wherePast`, `whereFuture`, `whereToday`, `whereBeforeToday`, `whereAfterToday` (and their `NowOr`/`Or` forms); `whereYear`/`whereMonth`/`whereDay` on model queries.
- `DB.whenQueryingForLongerThan`, `DB.totalQueryDuration`, `DB.withQueryCount`.
- `Context`: request data in log records, carried into dispatched jobs (hidden entries carried but not logged).
- `package:daravel/html.dart`: typed, escaped HTML builder; nodes are responses.
- `ScheduledTask.timezone()` accepts IANA zone names with Laravel's DST behaviour (adds `package:timezone`).
- Opening SQLite in a bundle built without it reports what is missing.

## 1.1.0

- Polymorphic relations (`MorphOne`, `MorphMany`, `MorphTo`, `MorphToMany`, `MorphedByMany`), `Relation.morphMap`/`enforceMorphMap`, `whereHasMorph`, schema `morphs()`; nested `whereHas('a.b.c')`; self relations aliased as `laravel_reserved_N`; `HasOneThrough`; `withSum`/`withAvg`/`withMin`/`withMax`/`withExists`; `QueryBuilder.selectSub`.
- `request.queryInt`, `queryDouble`, `queryBool`, `queryString` (no `await`); `RuleBuilder` chains (`Rules.required().email().max(255)`).
- `CACHE_PROCESS_L1_TTL` (near cache for the `process` store) and `CACHE_LIMITER` (`CacheRateLimitStore`, rate limits in a cache store).
- Fixed: nested transactions started together (`Future.wait`) could roll back each other's work; a query after its transaction finished ran outside it (now a `StateError`).
- Fixed: the database cache store lost concurrent `increment`s (now a compare-and-swap).
- Fixed: on PostgreSQL, `withCount` with a constraint and `whereNot` with bindings failed (misnumbered placeholders).
- Fixed: verifying a multi-lane argon2id hash could hang under load.

## 1.0.0

- First stable release: the Dart API follows SemVer from here on.
- File uploads: `multipart/form-data` bodies stream to temporary files as `UploadedFile` (`request.file`, `hasFile`, `store`, `storeAs`, `UploadedFile.fake`), with Laravel's `file`, `image`, `mimes`, `mimetypes` and `extensions` rules and kilobyte sizes. Types are detected from the content; PHP files are refused.
- Database drivers are pluggable (`withDatabaseDriver`, `DatabaseDriverFactory`, `RetryableErrors`); MySQL and MariaDB ship in `daravel_mysql`. `mediumText`/`longText` columns and named unique indexes match Laravel.
- `Http`: outgoing requests with Laravel's `Http::` API and `Http.fake()`.
- Maintenance mode (`storage/framework/down`, `PreventRequestsDuringMaintenance`).
- Fixed: the migrator and the `unique`/`exists` rules quoted identifiers with double quotes, which MySQL rejects.
- Fixed: SQLite "database is locked" when several isolates open a new database file at once.

## 1.0.0-beta.3

- Declared route metadata: `.validates(FormRequest)`, `.rules({...})`, `.returns(schema, name:, shape:)` and `.action(...)`; the kernel answers 403/422 before the handler and `request.validated()` returns the result. `rulesToJsonSchema` converts rules to JSON Schema.
- Typed input: `input<T>()` converts query and form strings (`?page=5` is `5` for `input<int>`), plus `integer()`, `float()`, `boolean()` and `string()`.
- Query strings and form bodies read bracketed keys like PHP (`ids[]=1&ids[]=2` is a list; `Request.queryInput`, `parseQueryString`). Form bodies are now nested maps.
- Fixed: on SQLite, queries from another request no longer run inside (and roll back with) an open transaction.
- Fixed: the access log measures time to response, without deferred work.
- PostgreSQL over a Unix socket (`DB_HOST=/cloudsql/...`).
- Monitoring hooks: `Job.tags`, `QueueDriver.oldestWait` (custom drivers must implement it), `QueueManager.pause` / `resume`, `DB.listen` with `QueryExecuted`.
- `.env.encrypted` decrypted in memory at boot (`EnvironmentEncrypter`, Laravel `env:encrypt` format); multi-line double-quoted `.env` values; `EmbeddedWorkers` and `serveWith(embedQueue:, embedScheduler:)`.
- Changed: `.env` expands only `${NAME}` (phpdotenv 5); a bare `$NAME` stays literal.
- Faster request path: no timer per request for long timeouts, cheaper request ids, no empty awaits.

## 1.0.0-beta.2

- `daravelLogoDataUri` and `daravelFaviconDataUri` for welcome pages.
- `ServeOptions` falls back to the platform `PORT` (Cloud Run, Railway, Render, Fly.io) and binds `0.0.0.0` when `APP_PORT` is unset.
- `DatabaseQueue` skips jobs pushed by a Laravel app sharing the `jobs` table instead of failing them (or crashing on Laravel's string `backoff`).

## 1.0.0-beta.1

First public beta: the complete Tier 1 framework (container and zones, HTTP kernel and routing, validation with Laravel's rules and messages, query builder, ORM, migrations, auth with Sanctum-compatible tokens and JWT, multi-isolate serving, cache and rate limiting, events, queues and scheduling, API resources, storage, logging and metrics), Laravel-compatible wire and storage formats locked by a conformance suite, a security regression suite, and the `Str` / helpers / collection support layer.

The full history of the Daravel workspace is in the
[repository changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).
