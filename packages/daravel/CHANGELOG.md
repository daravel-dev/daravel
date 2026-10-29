# Changelog

## Unreleased

- Changed: `daravelLogoDataUri` and `daravelFaviconDataUri` carry the new Daravel logo (an infinity loop).

## 1.19.0

- Fixed: `SqliteReplicator.sync` retries its marker row instead of failing when a writer holds the lock past `busy_timeout`.
- Fixed: `ProcessSupervisor` readiness ignores a TCP self-connection (Linux, ephemeral ports).
- Added the `date_format` rule (`DateFormatRule`, `Rules.dateFormat`, `phpDateMatchesFormat`), as Laravel's `validateDateFormat`.
- Added `partitioned` to `Response.withCookie`; `Response.json(phpCompatible: true)` (`Response.encodePhpJson`) writes a `PhpObject` as an object, `{}` when empty.

## 1.18.1

- Fixed: error bodies are pretty-printed like Laravel's `Handler::prepareJsonResponse` (every HTTP error, 500, 413), with 401 `Unauthenticated.` and 422 compact; `laravelErrorResponse`, `HttpException.prettyJson`, `phpJsonFromDart(escapeSlashes:)`.
- Fixed: the validator stops on an attribute after a failed implicit rule, and skips `unique`/`exists` after an earlier failure, as Laravel does (`laravelImplicitRules`).

## 1.18.0

- Added `Cast.dateTimeFormat('Y-m-d H:i:s')` (Laravel's `datetime:FORMAT` and `date:FORMAT` casts; `DateTimeFormatCast`) and `formatPhpDate` (every PHP `date()` token): `Model.toJson` writes the attribute in that format, in UTC, as Laravel 8 to 13 write a formatted timestamp; `model:show` names it `datetime:FORMAT`. An append that names an existing attribute keeps its position, as in Laravel. Both behaviours are the same in Laravel 8, 9 and 12 (ADR-025 §4), so `COMPAT_LARAVEL_VERSION` does not change them.
- Added `APP_PROCESSES` / `serve --processes=N` (ADR-027): `ProcessSupervisor` runs N server processes on consecutive ports for a reverse proxy, restarts one that exits, stops them together and prints the nginx `upstream` block; `serveWith(processes:, childArguments:)`, `selfArguments`, `watchSupervisorParent` (a child exits when its parent dies, even killed outright). The server refuses to start with per-process stores unless `APP_PROCESSES_ALLOW_UNSHARED_STATE=true`. The bench harness takes `--processes=N`.
- Added `package:daravel/foundation.dart`, `http.dart`, `database.dart`, `auth.dart` and `validation.dart`: subsets of the barrel for files whose own names collide with it (`JwtException`, `UniqueRule`, `ModelNotFoundException`, `CorsMiddleware`).
- `Crypt.encrypt`/`decrypt` carry values as PHP `serialize()` text, as Laravel's `Crypt::encrypt` does (ADR-026), so a map or list encrypted by either framework is read by the other; `phpSerialize`, `phpUnserialize`, `PhpObject`. A payload made by Daravel 1.17 or earlier (JSON) still decrypts.
- Added `Request.replaceCookies` (what a cookie-decrypting middleware calls), `Response.withHeaderList` (every value of a multi-valued header such as `Set-Cookie`) and `Encrypter.keys`.
- Fixed: the database cache store wrote `forever` entries with the constant expiration 9999999999, which overflows the `integer` column of Laravel's `cache` table on MySQL and MariaDB (clamped to 2038 without strict mode, rejected with it); it now writes ten years from now, as Laravel's `DatabaseStore::forever` does (`DatabaseStore.foreverTtlSeconds`).
- Embedded queue and scheduler isolates (`serve --embed-queue --embed-scheduler`) share the server's coordinator: the `process` cache store, rate limits and locks are the HTTP workers' (`EmbeddedWorkers(coordinator:)`); before, each embedded isolate had a coordinator of its own, so a token a job revoked stayed valid.
- Added `CACHE_PROCESS_MAX_ENTRIES` (`CacheConfig.processMaxEntries`, `createStandardCoordinator(processCacheMaxEntries:)`): the bound of the `process` store, 10 000 before and by default, was fixed.
- The conformance suite now cites laravel/framework 13.x (the fixture is regenerated from it; Laravel 10 to 12 write the same formats, ADR-025 §5); `tool/conformance/sync_laravel_messages.dart --branch=`.
- Added `COMPAT_LARAVEL_VERSION` (8 to 13, default 12; ADR-025): 9 answers with Laravel 8/9 validation messages, 8 also with `The given data was invalid.`, an empty 404 message and the `for this route` 405; 10 to 13 match the default. `AppConfig.laravelCompat`, `currentLaravelCompat()`, `ValidationMessages.legacyEnglish`.
- Added `Request.cookies`, `Request.cookie`, `Request.hasCookie`, `Response.withCookie` and `Response.withoutCookie` (Symfony's `Set-Cookie` format, Laravel's defaults).
- Added `Response.json(data, phpCompatible: true)`, `phpJsonFromDart` and `phpRawUrlEncode`; `phpJsonEncode` now runs in one pass.
- Added `isolateSizingAdvice` (logged by `serveWith` in production with one isolate on several cores), `Container.runBound` and `Container.currentOrNull`.
- Changed: boot runs with the application's container as `Container.current`, so facades work in providers, bindings and routing callbacks.
- Added `Request.current` (the request being handled, from anywhere in its zone; Laravel's `request()`), and exception renderers may be asynchronous (`ExceptionRenderer` returns `FutureOr<Response?>`; synchronous renderers are unchanged). `DB_STRICT`, `DB_SQL_MODES` and `DB_ISOLATION_LEVEL` reach the MySQL connection options.
- Added SQLite replication (Blueprint #30): `SqliteReplicator` ships a WAL-mode database to a `Disk` as a page-exact snapshot then its committed log frames, starting a new generation whenever it cannot prove it saw every frame; `restoreReplica` (newest, a generation, or a point in time, checked with `integrity_check`); `listReplicaGenerations`; the WAL reader (`WalHeader`, `readWalFrames`, `applyWalFrames`).
- Added `withUpstream(url:, preserveHost:, stripResponseHeaders:, timeout:)` and `UpstreamProxy`: requests no route matches, whatever their method, are streamed to another server (the Laravel application being migrated, `UPSTREAM_URL`) with `X-Forwarded-*` headers, cookies, redirects and compressed bodies passed through, 502 when it is down and 504 when it is too slow; `HttpKernel.unmatched`; `Request.bodyStream()`.

## 1.17.0

- Added `WorkerReportService` (in the standard coordinator) and `WorkerReports`: each worker isolate publishes its latest report on a topic and any worker collects them all; a worker that exits is forgotten.
- Fixed: `Application.shutdown()` after a boot that failed or never ran no longer throws `LateInitializationError` (`logger`).

## 1.16.0

- Added coordinator round-trip metrics: `RemoteCoordinatorChannel.onCallDuration` / `onCallTimeout`, recorded by `AppMetrics` as `coordinator_call_duration_seconds{service}` (sub-millisecond buckets, `AppMetrics.coordinatorBuckets`) and `coordinator_call_timeouts_total{service}`; `Coordinator.stats()` adds `in_flight_peak` and `max_queue`, exported as `coordinator_in_flight_peak` and `coordinator_max_queue`.
- The English validation messages carry Laravel's MIT notice (`THIRD_PARTY_NOTICES.md`).

## 1.15.0

- Fixed: a command in an application with `withPermissions()` (any package subscribing to a broadcast channel at boot) never exited; cancelling a subscription after `Broadcaster.close()` opened a new port that nothing closed.

## 1.14.0

- Added `HTTP_IDLE_TIMEOUT` (`ServeOptions.idleTimeout`, 60 s): how long a keep-alive connection may sit without a request before the server closes it; the field existed but could not be set from the environment.
- Added a WebSocket frame limit: `router.ws(..., maxPayloadBytes:)` and `Response.webSocket(maxPayloadBytes:)` (1 MiB, `Response.defaultWebSocketMaxPayloadBytes`); a larger frame fails the connection as it arrives. `dart:io` sets no limit of its own, so one client could make a worker buffer a frame of any size. The Pusher server caps frames at `REVERB_APP_MAX_MESSAGE_SIZE` plus 1 KiB.
- Added `HTTP_MAX_BODY` (`ServeOptions.maxBodyBytes`, 50 MiB, `0` for none): the body limit every request served by the engine starts with, so an application without `BodyLimitsMiddleware` never buffers an unbounded body.
- Added `DB_CONNECT_TIMEOUT` and `DB_QUERY_TIMEOUT` (seconds, `0` for none; `connect_timeout` / `query_timeout` connection options, `PostgresDriver.timeoutOption`): the PostgreSQL statement timeout was a fixed 30 s, so a long `CREATE INDEX` in a migration was cancelled.
- Fixed: PostgreSQL closes its pool when the `SELECT 1` probe fails after the connection opened (each retry leaked a backend), and `listen()` closes the dedicated connection when the listener cancelled during the handshake (it lived until process exit).
- Changed: `HmacJwtKey` (so `JwtCodec.hs256`) refuses an empty secret with `ArgumentError`; HMAC over an empty key signs and verifies like any other, so a secret that was never set accepted tokens anyone could mint.
- Added `ConnectionException.isTimeout`: true when the request was sent and the answer did not come in time (it may have been processed), false when the connection was refused or reset.
- Fixed: `DB.transaction(attempts: n)` no longer re-runs a committed body when an after-commit callback fails with a retryable error; the callbacks run outside the retry.
- Fixed: a SQLite connection whose setup fails after the file is opened (not a database, stays busy) closes its handle instead of leaking it with the file locked.
- Fixed: `MemoryStore` sweeps expired, unreleased locks once there are `maxEntries` of them (`lockCount`); `ProcessRateLimitStore` sweeps the state of keys it no longer limits once `maxKeys` (10 000) are tracked (`trackedKeys`). Both only grew before.
- Fixed: `withoutOverlapping` locks name the task and its cron expression and are taken separately from the single-server minute lock (a task with both used to take only the minute's lock, which protected nothing against overlap); an unnamed closure with `withoutOverlapping` is refused at run (every unnamed closure is named `Closure`, so they shared one lock), as Laravel does. `LocalDisk.putStream` writes through a temporary file and a rename, so a stream that fails leaves no truncated file.
- Fixed: `Scheduler.work` starts each minute's `run` without awaiting the previous one, as Laravel's `schedule:work` does; a task that hung, or ran for minutes, used to stop the scheduler and skip the minutes in between. Tasks within a minute still run in order.
- Fixed: the queue worker survives what used to end it: a Daravel-shaped row whose payload does not decode is removed and recorded in `failed_jobs` (`CorruptPayloadException`; it was re-reserved after `retry_after` and crashed the next worker too), a job whose `fromJson` throws fails like an unknown job, and a transient database or cache error in `pop` or the bookkeeping is logged and waited out. A job released after a timeout, whose handler Dart cannot cancel and is still running, makes the worker stop with exit code 1 (`JobProcessor.timedOutAndReleased`), as `queue:restart` does, so attempt 2 does not run beside attempt 1 in the same process.
- Fixed: `min`, `max`, `between` and `size` measure a string by its numeric value when the attribute also has a `numeric` or `integer` rule, as Laravel's `getSize` does (`ValidationContext.numeric`); every form and query input is a string, so `numeric|max:100` passed `"500"` by its three characters.
- Fixed: a disk path with a control character (a NUL, which Windows truncates a name at) is refused by `normalizeDiskPath`; a failed SMTP `AUTH LOGIN` no longer quotes the base64 password in its `SmtpException` (which reached `failed_jobs` and the log); a `MailAttachment` content type with a line break, or that is not a media type, is refused (it went straight into a part header); the STARTTLS handshake is bounded by `MAIL_TIMEOUT`; and a cron expression with both day fields set (`0 0 1 * 1`) matches either, as Vixie cron and Laravel do (it required both, so such schedules never ran).
- Fixed: the last frames of cache channels are bounded (`ChannelMembershipService.maxCachedFrames`, 10 000; expired ones swept first, then the least recently written); a frame stayed until its channel was read again, so one cache channel per user or document grew the coordinator without bound.
- Fixed: the error of a malformed `DB_URL` masks the password (`ConnectionConfig.redactUrl`); it used to quote the whole URL, `user:secret@` included, into `doctor`'s output and the boot log.
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
