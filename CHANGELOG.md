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

### Added

### Changed

**Upgrading can change what an application sees:**

### Fixed

## 1.27.3

A security patch: fixes only. Upgrade every application served by `dartisan serve` or the AOT server, above all those behind a proxy or load balancer and those with domain routes.

### Security

- A request's URI, `scheme`, `host`, `url` and `isSecure` came from `dart:io`'s `HttpRequest.requestedUri`, which reads `X-Forwarded-Proto` and `X-Forwarded-Host` from any client, also without `TrustProxiesMiddleware` and from a peer it does not trust. Domain routes, the host of signed URLs on domain routes, `Response.back`, the session's previous URL, the HSTS header and `UpstreamProxy` followed them. They now come from the request line, the `Host` header and the listener; forwarded values count only when `TrustProxiesMiddleware` trusts the peer, as in Laravel (Symfony's `Request::getHost()` and `isSecure()` read them only from a trusted proxy). Since 1.0.0.
- The request URI was built by joining the `Host` header with the request target, so characters such as `/`, `?`, `#` or `@` in `Host` changed the path or host the application saw. A `Host` (or absolute-form authority, or trusted `X-Forwarded-Host`) that is not a host and an optional port is now refused (400; a forwarded value is ignored), as Symfony refuses it, and the path and query always come from the request line. Since 1.0.0.
- Slashes were trimmed from request paths with a regular expression whose time grew with the square of a run of slashes inside the path, so one request held an isolate for seconds; this affected the 404 and 405 responses, `Request.url`, the paginator's path and `DaravelUri.path`. They are now trimmed in one pass, with the same results. `Str.plural` and `Str.singular` no longer take quadratic time on a long run of letters followed by another character. Since 1.0.0.
- Before upgrading, take public URLs from `APP_URL` (as `route()`, signed URLs, mail and storage already do), have the edge proxy drop `X-Forwarded-Proto` and `X-Forwarded-Host` from clients and refuse a malformed `Host`, and limit the length of the request URL there (for example 8 KiB).

### Added

- `Request.isFromTrustedProxy` (Laravel's `isFromTrustedProxy()`), which the fix needs: whether `TrustProxiesMiddleware` applied a trusted proxy's forwarding headers. The server logs one warning when a request carries `X-Forwarded-Proto` or `X-Forwarded-Host` that no trusted proxy applied; it is said once per isolate and carries no header value. `dartisan doctor`, in production with an `https` `APP_URL`, notes that the server speaks plain HTTP and that requests see `https` and the public host only from a proxy `TrustProxiesMiddleware` trusts.

### Changed

**Upgrading can change what an application sees:**

- Without `TrustProxiesMiddleware`, an application behind a proxy that sends `X-Forwarded-Proto`/`X-Forwarded-Host` used to see the client's scheme and host from those headers; it now sees `http` and the `Host` the proxy connects with (which may be an internal host and port), and `isSecure` is false, until it trusts the proxy: `middleware.use([TrustProxiesMiddleware(proxies: ['10.0.0.0/8']), ...])` (the starter has this line as a comment, and the deployment guide shows it). URLs built from `APP_URL` are not affected.
- A request whose `Host` is not a host and an optional port (letters, digits, `-`, `_` and dots, an IPv4 address or a bracketed IPv6 address; a raw IDN included) is answered 400 before it reaches the application.

## 1.27.2

A security patch: fixes only. Upgrade every application that validates lists with `distinct`, authorizes broadcast channels (`routes/channels.dart`) or reads `sum()` or `avg()` on PostgreSQL or MySQL.

### Changed

**Upgrading can change what an application sees:**

- `POST /broadcasting/auth` refuses with `403` a channel name the Pusher protocol does not allow (more than 164 characters with its prefix, or a character other than `A-Z a-z 0-9 _ - = @ , . ;`). No Pusher or Echo client sends one, and the WebSocket server already refused it.

### Security

- Channel patterns took time growing faster than linearly with the channel name: a pattern with two or more placeholders not separated by `.` (`chat-{a}-{b}`, quadratic) or side by side (`{a}{b}{c}`, cubic: 4.6 s for 1 000 characters). `POST /broadcasting/auth` passed a name of any length (up to the form body limit) to them, so one request from any logged-in user could hold a worker for hours in an application with such a pattern. Names are now checked as above, and patterns are matched in time linear in the name with the same matches and values as before. Since 1.10.0.
- The validation rule `distinct` scanned the whole list for each item, so its time grew with the square of the list length: 16 000 numbers took 15 s and 16 000 `items.*.id` 55 s, from a JSON body of under 100 KB, with the default configuration. It now counts the list once per validation run (`ValidationContext.memo`, new and optional) and decides exactly as before. Since 1.0.0.

### Fixed

- `sum()` and `avg()` of the query builder and model queries threw a cast error on PostgreSQL and MySQL whenever the database returned a decimal: on MySQL every `sum()` and `avg()` of an integer or decimal column, on PostgreSQL `avg()` of an integer or decimal column and `sum()` of a `bigInteger` or `decimal` column. The value is now read as Laravel's `numericAggregate` reads it (no `.`: an `int`, otherwise a `double`). `sum()` without rows stays `null` on 1.x. Since 1.0.0.
- The publish workflow publishes every package from one job, one after the other, with a fresh token per package, after a dry-run of all of them, and pins every action to a commit (1.27.1 published only 4 of its 22 packages at first, because a floating action version changed under it). Nothing changes for applications.

## 1.27.1

A security patch: fixes only. Upgrade every application that accepts multipart uploads, validates numbers sent by clients (`decimal`, `multiple_of`, `gt`, `gte`, `lt`, `lte`) or configures WebSocket origins with wildcards.

### Security

- Matching time that grows faster than linearly with the input, reachable from a client, so one request could hold a worker for minutes (a denial of service):
  - the parameters of a multipart part's `Content-Disposition` header: any route that reads multipart input (`request.all()`, `input()`, `file()`), with the default configuration; since 1.0.0;
  - the WebSocket origin check of the Pusher server, when `REVERB_ALLOWED_ORIGINS` (or `BroadcastApp.allowedOrigins`) holds a pattern with two or more `*`; the default `*` is not affected; since 1.10.0;
  - the validation rules `decimal`, `multiple_of`, `gt`, `gte`, `lt` and `lte` on a field a client sends (a JSON or form body within the default size limit is enough); since 1.22.0.

  All are now matched in time linear in the input, with the same results as before. `Http::fake` URL patterns use the same linear matcher.

### Fixed

- `Application.shutdown()` after a password was hashed could end the process before it returned, silently and with exit code 0: a command or seeder that hashed (`Hash.make`/`check`) and then shut down as its last step lost everything after the shutdown, its own output and the database connections' close included. Seen every time on Linux; a server is not affected. Since 1.27.0 for password hashing (since 1.23.0 for `Concurrency.run`).

## 1.27.0

For servers under real load, from a robustness audit of the foundations (#170). Every resource that could grow without bound now has a limit with a Laravel- or Pusher-like default: WebSocket and SSE send buffers, Pusher channels and client events per connection, metric series, log buffering, hashing isolates, outbound response bodies, and the JWT denylist, which no longer shares an evictable cache. Queue workers follow Laravel's attempt accounting and stop a timed-out job from committing (`CancellationToken`); SQLite transactions begin `IMMEDIATE`, retry busy errors and store dates as Laravel does; PostgreSQL keeps its pooled connections; the coordinator drops work whose caller already gave up; and unread or truncated request bodies no longer hold a worker. ADR-032 adds `SqlIdentifier`, opt-in typed model ids and `dartisan build --target-os` for cross-compiled bundles. Read Changed before upgrading: several defaults are new.

### Added

- Metrics: `MetricsRegistry(maxSeries:)` (`METRICS_MAX_SERIES`, 10 000 by default, `0` for no limit) keeps at most that many label sets per metric; updates for a new label set beyond it go to the metric's `{overflow="true"}` series (`overflowSeries`) and are counted in `metrics_series_dropped_total{metric}`. `MetricsService(maxSnapshotBytes:)` (16 MiB by default) refuses a larger worker snapshot and keeps the previous one, and the service forgets a worker that exited (`WorkerAwareService`). `AppMetrics.knownMethods`, `AppMetrics.methodLabel` and `AppMetrics.recordRequest` are what `MetricsMiddleware` uses (#149).
- Cache housekeeping (#167): `Cache.flushLocks()` (`CacheRepository.flushLocks`, `LockFlushingCacheStore`) releases every lock of a store, and `dartisan cache:clear --locks` does it after the flush. `Cache.pruneExpired()` (`PrunableCacheStore`, implemented by the `memory`, `process`, `file` and `database` stores) deletes the expired entries and locks a store keeps until they are read, and `dartisan cache:prune-expired [store]` runs it (schedule it hourly). `DatabaseStore(pruneLottery: (2, 100))` deletes the expired rows of `cache` after 2 in 100 writes and those of `cache_locks` after 2 in 100 lock acquisitions, never inside a transaction; `FileStore(pruneInterval: Duration(hours: 1))` starts a background prune from a write at most that often (`null`: never). `CacheRepository(onRefreshError:, refreshBackoff:)` and `CacheManager.onRefreshError` receive the errors of background `flexible()` refreshes (the application logs them). `FileStore.lockGrace`, `FileStore.pruning` and `MemoryStore.lockSweeps` are there for tests.
- JWT denylist (#169): `createStandardCoordinator(jwtDenylistMaxEntries:, onWarning:)` registers a `ProcessCacheService` named `ProcessCacheService.jwtDenylistServiceName` for revoked JWT ids, sized by `JWT_DENYLIST_MAX_ENTRIES` (`CacheConfig.jwtDenylistMaxEntries`, 100 000). `ProcessStore(service:)` talks to such a service, `ProcessCacheService` takes the name it is registered under, and `MemoryStore(onLiveEviction:)`/`liveEvictions` report entries evicted before they expired (also `live_evictions` in the service stats of `coordinator:stats`).
- `Application.readinessCacheTtl` (1 s) and `QueryTally.fingerprintCacheSize` (daravel_pulse, 512): see Changed (#165).
- Bounded send buffers for WebSockets and server-sent events (#150). `Response.webSocket` and `router.ws` take `maxBufferedBytes` (`Response.defaultWebSocketMaxBufferedBytes`, 4 MiB) and `slowClientCode` (`1008`); `Response.sse` and `sseStream` take `maxBufferedBytes` (`Response.defaultSseMaxBufferedBytes`, 1 MiB; `null` keeps pausing the source). `REVERB_MAX_BUFFERED_BYTES` (`BroadcastConfig.maxBufferedBytes`, 1 MiB) sets it for the Pusher server, whose slow clients are closed with `4100` (`PusherServer.slowClientCode`). `SlowClients` counts the clients closed this way and `/metrics` exposes them as `realtime_slow_clients_total` (`transport`, `worker`). `DrainSignal.onDrain(listener)` returns a function that removes the listener, and `DrainSignal.listenerCount` says how many are left. Guide: [Responses](docs/guide/responses.md#server-sent-events-and-websockets), [Broadcasting](docs/guide/broadcasting.md#origins-and-limits).
- Pusher server limits per connection (#152), matching Pusher Channels where it documents one: `REVERB_APP_CLIENT_EVENTS_PER_SECOND` (`BroadcastConfig.clientEventsPerSecond`, 10 as Pusher; `0` for none) drops client events past the rate with `pusher:error` `4301` "Rate limit exceeded" (Reverb's message) and keeps the connection; `REVERB_APP_VALIDATE_CHANNEL_NAMES` (`validateChannelNames`, true) refuses names other than Pusher's (at most 164 characters of `A-Z a-z 0-9 _ - = @ , . ;`) with `pusher:error` `4300`; `REVERB_APP_MAX_CHANNELS_PER_CONNECTION` (`maxChannelsPerConnection`, 100; `0` for none) refuses a subscription past the limit with `pusher:error` `4300`, the connection kept. `PusherServer.isValidChannelName` checks a name. `Broadcast.pipe`'s `onMessage` may be asynchronous: each message is awaited before the next is read. Guide: [Broadcasting](docs/guide/broadcasting.md#origins-and-limits).
- `HTTP_ACCESS_LOG` (`ServeOptions.accessLog`, default `true`): `false` stops the `info` line the server logs for every request, for when a proxy in front already writes an access log, without raising `LOG_LEVEL` past the application's own `info` logs (#162).
- `log_lines_dropped_total` on `/metrics`: log lines dropped because stdout, stderr or the daily log file fell behind or failed (#162). `MetricsRegistry.counter(collect:)` reads a counter kept elsewhere at render time, as `gauge(collect:)` does.
- `Concurrency.maxQueue` (no limit by default): the most tasks waiting for a busy worker isolate; past it a task fails at once with a `StateError` instead of queueing (#163).
- Outbound HTTP (#164): `PendingRequest.maxResponseSize(bytes)` and `HttpClientFactory.maxResponseBytes`, `connectTimeout` (10 s) and `maxConnectionsPerHost`; `ClientResponse.bodyBytes` gives the body as received, for binary responses. `UpstreamProxy(bodyIdleTimeout:, connectTimeout:, maxConnectionsPerHost:)`, and `shadow_replays_dropped_total` and `shadow_replays_failed_total` on `/metrics` for `withUpstream` shadow replays.
- Coordinator saturation is visible and stale work is skipped (part of #148). A `RemoteCoordinatorChannel` sends the call's deadline with an `ExpiringCoordinatorMessage` (a new interface: `RateLimitMessage` for `attempt`, `acquire`, `attempts` and `availableIn`, `LockMessage` for `acquireLock` and `lockOwner`), and the coordinator drops such a request unanswered when it reaches it after the deadline (`CoordinatorRequest.deadline`, counted in `coordinator_expired_total`): a rate-limit attempt or lease the worker already let through uncounted is no longer counted afterwards, and a lock its caller gave up on is no longer granted to nobody. Releases, writes and every other message are handled however late. The coordinator also measures its own event-loop lag every 100 ms (`queue_lag_ms` and `queue_lag_peak_ms` in its stats, `coordinator_queue_lag_seconds` and `coordinator_queue_lag_peak_seconds` on `/metrics`), the backlog of synchronous services that `coordinator_in_flight` never counted, and `dartisan coordinator:stats` prints both with advice. Guide: [Operations](docs/guide/operations.md#what-to-watch).
- `CancellationToken` and `OperationCancelledException` (#158): cooperative cancellation of a unit of work. `token.run(body)` makes it `CancellationToken.current` for everything the body starts, and `DB.transaction` checks the current token before it begins and before it commits (or releases a savepoint), rolling back with `OperationCancelledException` once the token is cancelled. Each job attempt runs with `JobContext.cancellation`, which a timeout cancels.
- `ReservingQueueDriver` (#158): a queue driver that reserves jobs for `retryAfter` and can `touch(job)` a reservation that is still its own. `DatabaseQueue` and `daravel_redis`'s `RedisQueue` implement it, and the worker touches a running job every half `retry_after`, so a job that runs longer than `retry_after` is not reserved again by another worker and run twice at once.
- `MaxAttemptsExceededException` (#158), Laravel's: the failure of a job reserved again after its last try or after its `retryUntil`.
- `queue:work --memory=<MB>` and `WorkerOptions.memory` (#161), Laravel's `--memory`: the worker stops with `QueueWorker.exitMemoryLimit` (12) once the process's resident memory reaches the limit after a job, for the process manager to start a fresh one. No limit by default. `QueueWorker.errorBackoff(sleep, errors)` is the wait between polls during an outage, and `DatabaseQueue(listenRetry:)` how long after a failed or dropped `LISTEN` the next one is tried (30 seconds).
- `EmbeddedWorkers(crashDelay:)`, `EmbeddedWorkers.defaultCrashDelay` and `EmbeddedWorkers.maxCrashesPerMinute` (#159): the wait before an embedded isolate that crashed is started again.
- `dartisan schedule:clear-cache` (`Scheduler.clearCache()`, #160), Laravel's: releases the overlap locks of `withoutOverlapping` tasks left behind by a scheduler that was killed. `Scheduler.stop(drain:)`, `Scheduler.runningTasks`, `Scheduler.overlapLockName` and `Scheduler.serverLockName`; `Scheduler.runTask(task, at:)` takes the start of the run.
- `PoolExhaustedException` (a `QueryException`, with `waited`): thrown by PostgreSQL, MySQL and MariaDB when no pooled connection becomes free within `DB_CONNECT_TIMEOUT` (#156). PostgreSQL reported a bare `TimeoutException: Failed to acquire pool lock.` wrapped in a `QueryException`, which read like a slow query; MySQL and MariaDB waited for ever (`mysql_dart` queues callers without a bound) and now give up after the connect timeout, handing the connection the pool gives them later straight back.
- `DB.listen`, `DB.listenTransactions` and `DB.whenQueryingForLongerThan` (and the `DatabaseManager` methods) return a function that removes the listener (#156). The registries only grew, so a listener registered per request leaked and slowed every later query of the isolate; register them once, in a provider. Listener lists are now copied when changed rather than on every query.
- `SqliteDriver(busyTimeout:)`, read from the connection option `busy_timeout` in milliseconds as in Laravel (5 seconds by default): SQLite's `busy_timeout` and the bound on waiting for this connection's transaction (below).
- `SqlIdentifier` and `SqlFragment` (ADR-032), extension types over `String`. `SqlIdentifier('users.id')` checks a column or table name once, where it is made: plain names joined by dots, else an `ArgumentError` (`SqlIdentifier.tryParse` and `SqlIdentifier.isValid` do not throw). It implements `String`, so every query builder column parameter accepts it as it is, and every grammar writes the same SQL as for the string. `RawExpression.sql` (`DB.raw(...)` and the `*Raw` methods) is now a `SqlFragment`, a `String` with no public constructor that documents where raw SQL flows; it does not check the text, and values still belong in bindings.
- `daravel_lints`: the opt-in rule `prefer_sql_identifier` reports a column argument of a query builder method (`where`, `orderBy`, `select`, `pluck`, ...) that is neither a string literal, a `const`, a choice between literals nor a `SqlIdentifier`. It is not in `defaultRules`, so `dartisan lint` does not run it; `optionalRules` lists the opt-in rules and `rulesWith(['prefer_sql_identifier'])` adds them to the defaults. `daravel_test`'s `expectLintClean(root, enable)` takes the opt-in rules to run by name: `expectLintClean(null, ['prefer_sql_identifier'])`.
- Typed ids, opt-in (ADR-032): `dartisan model:sync --typed-ids` writes an extension type per model (`extension type const UserId(int value) implements int`, with `UserId.parse`) in a new `// <dartisan:ids>` region from the new `model.id` stub, types the primary key getter, and retypes the generated `find`/`findOrFail` to take it, so a wrong-typed id is caught at compile time. The id is erased to the plain key at runtime: JSON, SQL bindings and Laravel-shared tables are unchanged. Without the flag `model:sync` writes what it wrote before. In the core: `TypedId<T>` (a generic id), `IdType` (`IdType.integer(UserId.new)`, `IdType.string(...)`) and `ModelDefinition(idType:)` with `parseId`/`idOf`, which route model binding uses to answer 404 for an id the parser rejects; `IdParsers` and `ApplicationBuilder.withIds` (`bootstrap/ids.dart`), parsers by route parameter name read by `request.param<T>(name)`, which also takes `parse:` (`request.param<UserId>('user', parse: UserId.parse)`). Parsers are keyed by name because extension types are erased, so `param<UserId>` cannot find one from its type. See the guide, Database, Typed ids.
- `dartisan build --target-os=<linux|macos|windows> --target-arch=<x64|arm64>`: a bundle for another machine, such as a Linux server built on Windows (ADR-032). Both go to `dart build cli`, which cross-compiles and runs the build hooks for the target, so the bundled SQLite is the target's (`libsqlite3.so`) and the executable has `.exe` only for Windows; the Dart SDK cross-compiles to Linux only. Before, `dartisan build -- --target-os=linux` was not passed on and built for the host. When the SQLite download fails with "Hash of downloaded file", `dartisan build` explains it (`package:sqlite3` 3.8.0 does not check the HTTP status of that download) and suggests running again or `--no-sqlite --force` for PostgreSQL and MySQL. CI builds the starter for Linux on Windows and smoke-tests it on Linux. Deployment guide, "Build on one OS, run on another".

### Changed

**Upgrading can change what an application sees:**

- `package:daravel/daravel.dart` now exports `SqlIdentifier` and `SqlFragment`, and `package:daravel_lints/daravel_lints.dart` exports `PreferSqlIdentifier`, `optionalRules` and `rulesWith`. An application that declares one of those names hides it in its import. `RawExpression.sql` is a `SqlFragment` getter where it was a `String` field; it is still a `String`, so reading it works as before, but a variable inferred from it (`var sql = raw.sql;`) can no longer be assigned a plain string: declare it `String`. The SQL every query writes is unchanged.
- `package:daravel/daravel.dart` now exports `TypedId`, `IdType` and `IdParsers` (typed ids, opt-in). An application that declares one of those names hides it in its import of `package:daravel/daravel.dart`. Nothing else changes until an application sets `ModelDefinition(idType:)`, registers a parser with `withIds`, or runs `model:sync --typed-ids`; once a parser is registered for a route parameter name, every `request.param` read of that name goes through it.
- `package:dartisan_cli/dartisan_cli.dart` now exports `buildCliArguments`, `bundleExecutableName`, `sqliteDownloadHint`, `buildTargetOses` and `buildTargetArchitectures` (`dartisan build --target-os`). A project command that declares one of these names hides it in its import of `package:dartisan_cli/dartisan_cli.dart`. `dartisan build` without the new options runs the same `dart build cli` as before.
- SQLite stores and compares a `DateTime` bound to a query (`where`, `insert`, `update`, raw SQL) as Laravel's `Grammar::getDateFormat()` writes it, `Y-m-d H:i:s` in UTC without fractions of a second, the format model casts and timestamps already used and the MySQL driver already sent (#178). It was ISO 8601 (`2026-11-05T17:40:36.052371Z`), so one row could hold both formats and, since SQLite compares dates as text, `where('ends_at', '>=', now)` was wrong for any same-day value a model had written (the space sorts before `T`). Values written by 1.26 and earlier still read back as dates, but compare wrongly against the new bindings; rewrite them once per column with `UPDATE t SET c = strftime('%Y-%m-%d %H:%M:%S', c) WHERE c LIKE '____-__-__T%'` (guide: [Database](docs/guide/database.md#dates-in-queries)). Framework tables written through the query builder on SQLite change the same way (`personal_access_tokens`, `failed_jobs`, Pennant's `features`) and now match what Laravel writes. A sub-second `DateTime` comparison on SQLite now compares whole seconds, as in Laravel. PostgreSQL is unchanged.
- SQLite transactions begin with `BEGIN IMMEDIATE` (Rails 7.1's default), and `DB.transaction(attempts:)` retries SQLite's busy and locked errors (`SQLITE_BUSY`, including `SQLITE_BUSY_SNAPSHOT`, and `SQLITE_LOCKED`) (#156). With several isolates on one SQLite file, a transaction that read, saw another isolate commit, and then wrote failed at once with `database is locked` and was never retried; it now takes the write lock when it begins (waiting up to the busy timeout), so a transaction that only reads also holds it, and every transaction of a file is serialized across isolates. A single isolate, the usual SQLite deployment, sees no difference.
- SQLite: a query outside a transaction that waits for that transaction to end (one connection per isolate) gives up after the busy timeout with `SqliteException(5) database is locked`, as a second connection would (#156). A query started outside a transaction and awaited inside it, such as a shared cache fill another request began, waited for ever. A transaction that runs longer than 5 seconds now makes concurrent queries of other requests fail where they waited; raise `busy_timeout` for such workloads.
- `DatabaseManager.closeAll()` closes each connection within `timeout:` (10 seconds by default; PostgreSQL closes its pool by force after 5) and goes on when one throws or hangs, logging it; the first error is rethrown once all were tried (#156). An abandoned transaction held PostgreSQL's `pool.close()` and the whole shutdown, and a throwing driver left the others open.
- `package:daravel/daravel.dart` and `package:daravel/foundation.dart` now export `CancellationToken` and `OperationCancelledException`, and `package:daravel/daravel.dart` exports `ReservingQueueDriver` and `MaxAttemptsExceededException` (#158). An application that declares one of these names hides it in its import.
- Queue attempts follow Laravel's worker (#158). A job reserved again after its last try (a release by `WithoutOverlapping`, `RateLimitedJob` or `ctx.release()` counts as an attempt, as before) now fails with `MaxAttemptsExceededException` without running, where it was released for ever; so does a job reserved after its `retryUntil`. A job released while it waits for a lock needs `tries` or `retryUntil` that cover the wait. `Job.maxExceptions` is now `int?` and null by default (Laravel's `$maxExceptions`), and is enforced: a job fails after that many exceptions, counted in the unique-lock store under `job-exceptions:<uuid>`; before, it defaulted to `tries` and was ignored. `JobPayload.maxExceptions` is `int?` too, and a payload without the key reads as null.
- `Queue.dispatch(job)` pushes the job even when nothing awaits the `PendingDispatch` (#158), in a microtask after the setters chained on it, as Laravel pushes from `PendingDispatch::__destruct`. Before, a dispatch that was not awaited never pushed. A setter called after the push throws `StateError`, and a failed push that nothing awaits is logged at error level.
- A job handler's uncaught asynchronous error (a future it did not await) fails the attempt once the handler has returned (#158); before, it failed the attempt at once and the retry started beside the still-running handler. `Container.runScoped` with `onUncaughtError` now reports every such error there and completes with the body's own result; without `onUncaughtError` it behaves as before. In HTTP requests (which pass one) a stray error is logged and the response is the handler's, where the request scope failed early.
- A job past its timeout keeps its `WithoutOverlapping` lock until `expiresAfter` instead of releasing it while its handler still runs (#158), and `dartisan queue:work` ends the process when the worker stops for a restart (exit code 1), so a handler that outlived its timeout cannot keep the old process alive.
- `serve` refuses `QUEUE_UNIQUE_LOCK_STORE=memory` (a store of one isolate) with `APP_ISOLATES` above 1 or `--embed-queue` (#161): each isolate kept its own unique and debounce locks, so a unique job could be dispatched once per isolate and the worker never released the lock a request took. Use `process` (the default), `database` or `redis`.
- A `queue:pause` flag that cannot be read (the signal store fails) is taken as not paused and logged, where the worker stopped taking jobs from that queue until the store was back (#161). During an outage the worker logs the first error with its stack trace and then at most one a minute, and waits longer between polls (`--sleep` doubled per error, up to a minute).
- Embedded workers (`serve --embed-queue --embed-scheduler`, #159): an isolate that ends on its own (a queue worker restarting after `queue:restart` or a timed-out job) is started again at once and no longer counts as a crash; a crashed one waits a second per crash in the last minute and, past five crashes in a minute, a minute between attempts, logged as an error each time, where the role was given up for good (logged once) while the server kept serving. `serve` refuses `QUEUE_CONNECTION=memory` (an isolate-scoped queue) with `APP_ISOLATES` above 1 or `--embed-queue`, whose jobs were never processed: use the database or redis queue.
- Scheduler (#160): `Scheduler.run` no longer throws when a task's filter, lock store or listener does; the task is logged and skipped (`TaskRunResult.error`, `skipped: 'error'`, `ScheduledTaskSkipped` with reason `error`) and the others still run, so `schedule:run` reports it instead of failing the minute. `work()` now waits, once stopped, for the tasks under way (30 seconds by default, `stop(drain:)`), and releases the overlap lock of any still running. `onOneServer` locks are named after a hash of the task's expression and name (for an unnamed job, its name and data) and the run's start `HHmm`, as Laravel's `SchedulingMutex`, where they used the name and the dated current minute: a scheduler running the release before and one running it after may both run an `onOneServer` task in the minute of the deploy. An unnamed closure with `onOneServer()` is refused, as with `withoutOverlapping()`.
- `ThrottledReporter` is a new export of `package:daravel/daravel.dart` (#147): it reports at most one error per interval with the count of the skipped ones, and the application uses it for the rate limiter's warning. An application that declares a class of that name should hide it from the import. `CacheRateLimitStore` (`CACHE_LIMITER` other than `process`) now lets a request through, uncounted, when its cache store throws, where the request failed with a `500` before; give the limit `failsClosed()`, or construct the store with `failClosed: true`, to answer `429` instead.
- `throttle:<max>,<minutes>` (a `ThrottleMiddleware` without a named limiter) keys a guest by the matched route's domain and the client address, as Laravel's `ThrottleRequests::resolveRequestSignature` does (#168). It used `method|Host header|path|ip`, so every route had a bucket of its own, and a client could get a fresh bucket per request by changing the `Host` header it sends. Every route under such a limit on one domain now shares the client's bucket, as in Laravel: a group throttled with `throttle:60,1` allows 60 requests a minute across its routes, not 60 per route. A route that needs its own budget can use a named limiter (`Limit.perMinute(60).by('${request.path}|${request.ip}')`) or a `prefix`. Users found by `userKeyResolver` are keyed by their id as before.
- `ExpiringCoordinatorMessage` is a new export of `package:daravel/daravel.dart` (#148), and `RateLimitMessage` and `LockMessage` implement it: a counting rate-limit call or a lock acquisition that reaches a stalled coordinator after its caller timed out is now dropped instead of counted or granted late. The worker already treated that call as failed (fail open, or a timeout for a lock), so what it sees does not change; the coordinator's counters do.
- Console and JSON log output written to the process's stdout and stderr is now asynchronous (#162): `ConsoleHandler` and `JsonHandler` without a sink queue lines in front of `stdout.nonBlocking`/`stderr.nonBlocking`, so a pipe nobody drains (a slow log collector) delays log lines instead of blocking the worker's event loop. Lines printed directly to stdout can now interleave differently with log lines, past 8 MiB waiting a line is dropped and counted, and `Logger.close()` (which `Application.shutdown` calls) waits up to 5 s for the queue. Handlers given a `StringSink`, and output inside `IOOverrides.runZoned`, are written synchronously as before. `package:daravel/daravel.dart` exports the new `LogLineQueue`; an application that declares that name hides it in its import.
- Password hashing is bounded (#163): `Hash.make` and `Hash.check` run on at most `HASH_CONCURRENCY` warm isolates (default: one per processor) instead of a fresh isolate per call, with up to `HASH_QUEUE` hashes (1024; `0` for no limit) waiting at most `HASH_QUEUE_TIMEOUT` (`30s`) each. Past either a hash fails with the new `HashingSaturatedException`, an `HttpException` answered as `503` with `Retry-After: 1`, where a login burst used to start an isolate per attempt until memory ran out. Hashes stay bcrypt `$2y$` by default and `HASH_VERIFY` is unchanged (ADR-024). `package:daravel/daravel.dart` exports `HashingSaturatedException`; an application that declares that name hides it in its import.
- `Concurrency.run(timeout:)` and `runBytes(timeout:)` now count the wait for a worker (#163): a task queued behind other callers' tasks fails with a `TimeoutException` once its timeout passes, where it waited for the whole queue and then had the full timeout to run. Without `concurrency`, one call hands the pool at most `Concurrency.maxWorkers` tasks at a time, so its own tasks do not eat into each other's timeouts.
- Outbound HTTP responses are capped at 32 MiB by default (#164): a larger body throws the new `ResponseTooLargeException` (not retried) and closes the connection, where it was read into memory whatever its size. Raise or remove the cap per request with `maxResponseSize(bytes)` (`null` for none) or for the application with `HttpClientFactory.maxResponseBytes`. A request's `timeout` is now one deadline for connecting, sending and reading the body, where each of the three phases had the full timeout, and connecting is capped at 10 s (`connectTimeout`, Laravel's `connect_timeout`). TLS failures are `ConnectionException`s, so `retry()` retries them. `ClientResponse.body` decodes malformed UTF-8 as U+FFFD instead of failing with a `FormatException`. `package:daravel/daravel.dart` exports `ResponseTooLargeException`; an application that declares that name hides it in its import.
- WebSocket clients that read too slowly are disconnected (#150): once more than 4 MiB (Pusher server: 1 MiB, `REVERB_MAX_BUFFERED_BYTES`) wait to be sent to one client, the backlog is dropped and the socket is closed with `1008` (Pusher: `4100`), where `dart:io` queued every frame in memory for as long as the client stayed. A route that pushes large bursts to slow clients raises `maxBufferedBytes`. The socket a `router.ws` handler gets is now a wrapper around `dart:io`'s `WebSocket` (it implements `WebSocket`), and frames added after it started closing are dropped instead of throwing `StateError`. `Response.sse` no longer pauses its source while the client is behind: it keeps reading and ends the stream with `retry: 1000` once more than 1 MiB waits, so a fast finite source sent to a slow client can now end early; `maxBufferedBytes: null` restores pausing. `package:daravel/daravel.dart` now exports `SlowClients`; an application that declares that name hides it in its import.
- `REVERB_SCALING_ENABLED` (#153): `broadcast_members.server` and Redis members now name the worker isolate (`<server>/<worker>`), and `broadcast_servers` holds one heartbeat row per worker isolate rather than per process. Servers running the previous release read both forms. Without `NOTIFY` (MySQL, MariaDB, SQLite) an idle relay reads once a second, so the first frame after a quiet spell can take up to a second to reach the other servers.
- The Pusher server now enforces per-connection limits (#152): more than 10 client events a second from one connection are dropped with `pusher:error` `4301`, channel names outside Pusher's rule (164 characters of `A-Z a-z 0-9 _ - = @ , . ;`; a `#`, `/`, `:` or space is refused) get `pusher:error` `4300`, and a connection may hold at most 100 channels. Each is configurable (`REVERB_APP_CLIENT_EVENTS_PER_SECOND`, `REVERB_APP_VALIDATE_CHANNEL_NAMES`, `REVERB_APP_MAX_CHANNELS_PER_CONNECTION`; `0`/`false` turns it off). `Broadcast.pipe` reads the client's next message only once an asynchronous `onMessage` has finished, where messages were handed over as fast as they came; an error thrown by `onMessage` is still reported to the zone and the next message read.
- The `method` label of `http_requests_total` and `http_request_duration_seconds` is `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS` or `other`: a request with any other method (which `dart:io` accepts and the kernel answers with 404/405) is counted as `other` instead of under its own name. A metric with more than `METRICS_MAX_SERIES` label sets per worker now counts the excess in `{overflow="true"}`. Under a supervisor a worker publishes its snapshot when it changed and every 15 s regardless, instead of every second, so a gauge computed at render time (`gauge(collect:)`) of another worker can be up to 15 s old on `/metrics`; the in-flight gauge of a worker that exited is no longer served. The new top-level `overflowSeries` constant is exported from `package:daravel/daravel.dart` (#149).
- Cache (#167): `flush()` and `dartisan cache:clear` keep the locks of the `memory`, `process`, `file` and `database` stores, as Laravel's `ArrayStore` and `DatabaseStore` do (they emptied `cache_locks` and every in-memory lock); use `flushLocks()` or `cache:clear --locks` to release them. The `database` store deletes expired rows of `cache` and `cache_locks` by lottery, and the `file` store prunes expired files in the background at most once an hour; a Laravel application sharing the tables sees expired rows go sooner, which it treats as misses anyway. A failed background `flexible()` refresh is logged at error level with the key and keeps its guard for 5 s, instead of surfacing as an uncaught error of the request (or ending a script); a waiter of `remember()` polls the value with a growing, jittered interval (10 to 100 ms) instead of retrying the lock every 100 ms. `ThrottleMiddleware` built in code without `limiter:` counts in the application's `RateLimiter` (its store and named limiters) instead of a per-isolate in-memory one. Expired `MemoryStore` entries and `MemoryRateLimitStore` windows are evicted before live ones when the store is full. `FileStore` lock files are written by a rename under the lock's OS mutex; a lock file written by an older version that is empty or unreadable counts as held for `FileStore.lockGrace` (2 s), then as free.
- With an in-memory cache store (`CACHE_STORE=memory` or `process`), revoked JWT ids live in a coordinator store of their own instead of the shared `process` cache, so they no longer count against `CACHE_PROCESS_MAX_ENTRIES`, and ids written there before the upgrade are not carried over (a restart empties both anyway). A coordinator an application builds itself without `createStandardCoordinator` keeps the ids in the `process` store, as before (#169).
- `/up/ready` runs its checks once at a time per worker and answers the probes of the next second (`Application.readinessCacheTtl`) from that result: a check whose state changes shows on the probes up to a second later. Every probe used to run `SELECT 1` and a cache write, read and delete in parallel, so frequent probes against a slow database pinned pool connections. Pulse keeps the fingerprints of the last 512 statements per isolate instead of running three regular expressions on every query. `Number.useLocale` and `Number.useCurrency` are documented as isolate-wide (set them at boot; pass `locale:`/`code:` per call) (#165).

### Fixed

- A failing `ROLLBACK` no longer replaces the error that caused it (#156). When SQLite had already ended the transaction (`SQLITE_FULL`, or a SQL dump's own `COMMIT` in the body), the caller saw `cannot rollback - no transaction is active`; the SQLite driver now rolls back only an open transaction, ignores a failing rollback and rethrows the body's error with its stack trace. A savepoint whose `ROLLBACK TO` fails also rethrows the body's error, still reports `DbTransactionRolledBack`, and closes the levels above it, whose later queries fail instead of running outside a transaction.
- A database driver factory that throws (a secret not available yet) is called again on the next query instead of its failure being cached for the life of the isolate (#156).
- `DB.transaction(timeout:)` keeps its promise through savepoints (#154): nothing a timed-out body does reaches the database. A nested `DB.transaction` called after its level timed out ran its `SAVEPOINT` on the raw connection, outside any transaction on SQLite (where `RELEASE` then committed it) or inside the transaction around a timed-out savepoint, which committed it; a savepoint still open when its parent timed out kept writing (in autocommit on SQLite); and a query of the timed-out level waited for that savepoint's body before failing. Closing a level now closes the savepoints open under it with the same error, a savepoint refuses to start, release or roll back under a level that has ended (`TransactionTimeoutException`, or the `StateError` of a query that outlived its transaction), and a query of an ended level fails at once. The timeout suite also runs on MySQL and MariaDB.
- PostgreSQL (`PostgresDriver`, re-exported by `daravel_postgres`): a transaction that rolls back keeps its pooled connection (#155). `package:postgres`'s pool closes the connection behind any error that is not a `PgException`, and a body's errors never are (statement errors arrive as `QueryException`, timeouts and application errors are the application's own), so every rollback, every deadlock retry and every `rollbackAfter` test paid a full reconnect, serialized by the pool. The driver now carries the body's error out of the pool as a value and rethrows it with its stack trace; `runTx` has already rolled back, and a connection the error did break is still discarded.
- Queue worker (#158): a handler that outlived its timeout could commit a transaction after its job was released or recorded as failed; it now rolls back (`OperationCancelledException`). A job that ran longer than `retry_after` on the database or Redis queue was reserved again by a second worker while it ran; the worker now extends the reservation of a running job and warns when a job's timeout (or `--timeout`) is not below `retry_after`. Releases never used up `tries`, so a job blocked by `WithoutOverlapping` was released for ever (and on MySQL a row's `TINYINT` `attempts` eventually overflowed and stalled the queue); `maxExceptions` was never enforced. A `Queue.dispatch()` that was not awaited never pushed.
- Queue bookkeeping (#161): a `JobProcessing` listener that threw left the job reserved (re-run after `retry_after` on the database queue, stuck for good on the memory queue), and a throwing `JobExceptionOccurred`, `JobProcessed` or `JobFailed` listener skipped the release, the failure record or the unique-lock release; such errors are now logged and the bookkeeping goes on. A signal store that failed (`queue:restart` read) ended the worker, as did an error while it waited for work, so a worker started during a database outage died; both are now retried. On PostgreSQL a dropped `LISTEN` connection was never opened again. A push that failed left its unique lock behind (a year by default, skipping every later dispatch of that id) and its debounce owner, so the dispatch already queued was dropped as superseded. `EventDispatcher.listen` kept registration order among listeners of one priority only up to 32 listeners (`List.sort` is not stable). `daravel_redis`: a job whose payload does not decode stayed reserved and was popped again after every `retry_after`; it now goes to `failed_jobs`, as on the database queue. A failure to record a corrupt payload in `failed_jobs` no longer ends the worker.
- Embedded workers (#159): every exit of an embedded isolate, a requested restart included, counted toward the crash budget, so the queue worker stopped for good after five restarts in a minute; and any uncaught asynchronous error in the isolate (a `JobFailed` listener's fire-and-forget future, a background task's lock release) ended it in the middle of its current job. Such errors are now logged and the isolate goes on. The exit outcome now arrives on the same port as the exit, so it is never read too late.
- Scheduler (#160): `stop()` returned from `work()` while tasks still ran, so a deploy or `SIGTERM` during a `withoutOverlapping` task left its lock for 24 hours and the task was skipped as an overlap until then. One throwing filter (`when`) aborted the rest of the minute, every minute, and so did an `onOneServer` task on a non-cluster lock store; a throwing `ScheduledTaskStarting` listener leaked the overlap lock. `onOneServer` keyed its lock on the task name and the scheduler's current minute: two unnamed closures, or two unnamed jobs of one class, blocked each other on every minute, a slow task carried the next one into the following minute's key so it ran on two servers, and each task left a `cache_locks` row per minute for ever (the key held the date).
- `ProcessRateLimitStore` no longer refuses users at a fraction of a limit when requests for one key overlap (#146). Concurrent attempts each leased their own batch of hits from the coordinator and overwrote one another's lease, so the hits of every overwritten lease were counted but never served: with 32 concurrent attempts per round on a limit of 1000, 185 were allowed. Attempts now share a single lease request per key and worker, the next request asks for as many hits as attempts are waiting (up to `maxLease`), and a lease is never replaced while it has hits left. A timer retires expired leases every `leaseTtl`, so a worker that goes quiet gives its unused hits back instead of holding them until the key is asked for again, and a lease granted after `timeout` (the request went through uncounted) is given back when the late answer arrives. `retireExpired()` runs that sweep on demand. Batching works under concurrency as designed: fewer than one coordinator call per eight throttled requests in the regression test.
- Coordinator failures no longer make things worse than they need to (#147). A `process`-store lock acquisition whose answer timed out, though the coordinator had granted it, left the lock held by nobody until its TTL (10 s for `Cache.remember`, 30 s for `flexible`): `ProcessStore.acquireLock` now sends a release for its owner right after the timeout (owner-checked, so a no-op when the lock is someone else's; the coordinator answers a worker's messages in order, so it follows the acquisition) before rethrowing, and `Lock.block` counts such a try as not acquired and tries again. `CacheRateLimitStore` (`CACHE_LIMITER=database`, `redis`) caught no store error, so a database or Redis blip turned every `throttle:` route into a `500`: it now fails open like the process store (`RateLimitResult.degraded`, `onError`), or closed with `failClosed: true` or a `Limit.failsClosed()` limit. The rate limiter's "could not count an attempt" warning is logged at most once a second, with the number of attempts it skipped, instead of once per attempt on top of the overload that caused it. And the `process` store's near cache (`CACHE_PROCESS_L1_TTL`) no longer serves a value past the value's own TTL: a write keeps it for the shorter of the two, and a read asks the coordinator how long the value has left (`getWithTtl`/`manyWithTtl`).
- `ThrottleMiddleware` no longer puts the request's `Host` header in its key (#168): one address rotating `Host` values was never throttled and added a bucket per value to the coordinator's store. See the upgrade note under Changed.
- Logging (#162): a daily log file that could not be opened or written (a full disk, a permission, a directory in its place) was an uncaught asynchronous error, which killed a supervisor worker at boot and, through the respawn limit, the whole server, or, inside a request, silently dropped every later line of the day. `DailyFileHandler` now owns the error path: one notice on stderr, the lines dropped and counted, the file opened again 5 s later (`retryAfter`). Its lines wait in a byte-bounded queue (`maxPendingBytes`, 8 MiB) written by one loop instead of an `IOSink` that buffered without limit while the disk was slower than the log rate, rotation closes the previous day's file only after its lines are written, and `close()` waits for them (up to `closeTimeout`, 10 s).
- Compute pool (#163): a worker spawn that failed (an isolate exiting at start, memory pressure) left the tasks queued behind it waiting for ever; each waiting task now gets a spawn of its own, or the error. `HashManager.checkAgainstDummy` cached a failed dummy hash for ever, so every later call for an unknown user rethrew it; the failed hash is now made again by the next call.
- Outbound HTTP (#164): a request that timed out kept its connection and went on reading the body into memory until `HttpClientFactory.close()`; the connection is now closed on a timeout, and the body read stops. `UpstreamProxy` (`withUpstream`) answered 504 but left the upstream request open, one socket (and, behind PHP-FPM, one worker) per timed-out request until the upstream answered; it now aborts it, as `shadow()` does on a timeout, a failure or a body over the limit. A connection that opens after the timeout is closed too, an upstream that stalls mid-body ends the response after `bodyIdleTimeout`, the upstream has 5 s to accept a connection, and headers named by a `Connection` header are not passed on in either direction (RFC 9110 §7.6.1).
- A request whose body the application does not read (every 404 and 405, a 401, 403 or 429 from middleware, the `413` refusing a declared `Content-Length`, a handler that ignores the body) is answered without waiting for that body (#144). Without a reader `dart:io` read the whole declared body before it wrote the response, with no timeout: a client that sent its body slowly, or stopped, held the response and its in-flight slot for as long as it kept the socket open (two of them made a worker with `HTTP_MAX_IN_FLIGHT=2` answer `503` to everyone), and a `413` refusing a declared gigabyte went out after the gigabyte. The server now takes such a body off the connection itself, as Go's `net/http` does: a body of at most 256 KiB (`ServerEngine.unreadBodyDrainLimit`) is waited for up to 1 s (`unreadBodyDrainTimeout`, never above `HTTP_REQUEST_TIMEOUT`) so the connection stays open; a larger, chunked or late one is not, the response goes out at once and the connection is closed after it. That close is graceful: the server sends the response, half-closes the connection and keeps reading what the client still sends for up to a second, so the client reads its `413` or `404` instead of a connection reset. Requests refused by load shedding and malformed requests are answered the same way. `Request.hasUnreadBody` tells whether the body is still unread, and `Request.bodyStream()` now claims the body when it is called rather than when its stream is first listened to.
- A `multipart/form-data` body that ends or fails inside a part (an upload interrupted mid-transfer, a body without its closing boundary, the body limit reached inside a file) answers `400` (`413` for the limit) at once instead of hanging the request for ever (#145). `package:mime` reports the end of the body only on the stream of parts, never to the part being read, so the parse waited for that part indefinitely, and because the global `MethodOverrideMiddleware` parses form posts before routing, the request timeout did not apply: every such request kept its in-flight slot, a file descriptor and a temporary upload file until the server restarted. The parser now fails the part being read as soon as the body ends or fails, and deletes the file it was writing.
- `parseQueryString` (query strings and form bodies) and the nesting of multipart fields run in linear time for `name[]` appends (#166). Each `[]` scanned every key of its list to find the next index, so a 389 KB form of 40 000 `a[]` pairs, well inside the 1 MiB form limit, blocked a worker for 12 s; 100 000 pairs now parse in milliseconds. The next index is still one past the highest integer key, as PHP's `parse_str` gives it.
- WebSockets and server-sent events no longer buffer without limit for a client that stops reading (#150): `Broadcaster.pipe`, the Pusher server and every `router.ws` handler send through a counted queue, and SSE streams count what the client has not taken (see Changed). Every finished `Response.sse` left a listener on `DrainSignal.future`, holding the stream, its source and whatever it captured until shutdown; streams now remove theirs when they end. A publish racing a server-side close no longer logs `Bad state: StreamSink is closed` per open socket.
- Broadcasting recovers from coordinator failures (#151). A failed `broadcast.subscribe` (a timeout, a full queue) no longer leaves the channel dead in that isolate until a restart: the subscriber gets the error and the next one registers again. A failed unsubscribe is retried when the next message for the channel arrives with nobody listening, and a registration racing an unsubscribe of the same channel waits for it. A Pusher connection whose `leave` fails on close still leaves its other channels (each `leave` is tried twice, then logged), so no ghost members or dead listeners stay behind. A coordinator or scaling-store failure while handling a client message closes the socket with `4100` after a `pusher:error`, where the read loop ended and left a zombie connection until the ping timeout. A scaling relay whose first start failed (Redis down) is no longer cached as failed: the next client starts it again, and the refused client gets `4100`. `PusherServer.publish` sends to several channels at once instead of one round trip after another.
- Broadcast scaling state stays clean (#153). With the database driver a connection that subscribed twice to a channel inserted a second `broadcast_members` row that was never deleted, keeping the user present for ever; a re-subscribe now replaces the connection's row (as Reverb replaces its entry), `leave` deletes every row of the connection on the channel, and neither the database nor the Redis driver announces `member_added` again for it. Members are recorded per worker isolate (`<server>/<worker>`, `DatabaseChannelState.worker`/`RedisChannelState.worker`, `instance`), each isolate beats on its own, and a worker respawned under the same name deletes what its previous life left at its first beat, so a crashed worker's connections stop counting after 30 seconds instead of for as long as the process lives (database and Redis). The database relay backs off to one read a second while no frames flow (`DatabaseBroadcastRelay.idlePoll`), where each worker isolate read every `REVERB_SCALING_POLL`, and `close()` waits for its loop, so no read runs after the application closes the database.
- Presence joins and leaves on the coordinator no longer rebuild the member list from every socket of the channel (#152): members are kept per user with a connection count, so a leave is constant time and a join copies the list once for its snapshot; `connections` (`/metrics`, `coordinator:stats`) is a counter instead of a set of every socket built per scrape. An incoming Pusher message is no longer UTF-8 encoded just to measure it when it cannot exceed `REVERB_APP_MAX_MESSAGE_SIZE`.
- Metrics: the HTTP `method` label took any token a client sent, so 100 000 requests with distinct methods made 100 001 series in two metrics on every worker (+362 MB RSS on one, a 119 MB `/metrics` body and a 930 ms merge on the supervisor's event loop per scrape). Methods outside the standard set are now `other`, every metric is capped by `METRICS_MAX_SERIES`, the coordinator refuses oversized snapshots, and the middleware no longer sorts, escapes and joins the labels on every request (the route label is escaped once per route, the worker label once) (#149).
- `FileStore`: concurrent writes of one key in an isolate went to disk together and their renames over the entry failed against each other on Windows, each retried with a backoff; 200 of them timed out `file_store_processes_test.dart` on a Windows CI runner. Writes of a key in an isolate now run one at a time, and those queued behind a running write collapse into the newest, which completes them all (200 concurrent `put`s of one key: about 1 s to 6 ms on Windows). The temporary file is no longer fsynced before the rename, as Laravel's `file_put_contents` does not; a cache entry can be lost to a power failure, never half written (#167).
- Cache stores (#167): a failing `flexible()` loader was relaunched on every stale hit, its error was an uncaught error of the request (a script exited 255, a bare isolate died), and the caller never learned of it; it is now reported through `onRefreshError`, backs off, and a refresh already running in the isolate takes no lock round trip. `remember()` waiters polled the lock every 100 ms against a wall-clock deadline (49 of 50 waiters got a value computed at 30 ms only at 105 ms, with 250 coordinator messages); concurrent misses in an isolate now share one computation and waiters poll the value from 10 ms. `flush()` released every lock, so `cache:clear` could give a held lock to a second holder. Expired rows and files were never deleted unless read again. `MemoryStore` swept its whole lock map on every new lock once `maxEntries` locks were live (0.9 µs to 81 µs per acquire at 10 000); the sweep is now amortised. `MemoryStore` and `MemoryRateLimitStore` evicted live entries while expired ones stayed. `FileStore.acquireLock` deleted a lock file another process had created but not written yet and took the lock too (3 double grants in 300 rounds), and `releaseLock` could delete the lock of the next owner after an expiry; both now run under the lock's OS mutex, and the lock file is written whole by a rename. `ThrottleMiddleware(...)` built in code counted per isolate in memory, so `failClosed` could never trigger, and `limiterName:` threw "Rate limiter [x] is not defined".
- A revoked JWT could be accepted again before it expired: with an in-memory cache store the denylist shared the `process` store, an LRU of `CACHE_PROCESS_MAX_ENTRIES` (10 000) entries, so an application caching more keys than that there evicted revoked ids silently. They now have a store of their own that only revoked ids fill, which drops expired ids first and logs a warning the first time it has to drop a live one (#169).

## 1.26.0

For applications built on Daravel day to day, from the first reports of a team running it in production. Static files are served by the framework, traversal-proof, with content-hashed URLs and `asset()`; sessions gain Laravel's `redis` and `cache` drivers and no longer hit a duplicate key on MySQL; `SecurityHeadersMiddleware` sends a Content-Security-Policy with per-request nonces; `html.dart` helpers take ids, classes and attributes everywhere and know htmx; and `TestClient.browser()` tests web routes with cookies, CSRF and session assertions. Underneath, rate limits can fail closed, `DB.transaction` takes a timeout, and the coordinator moves typed, deeply-immutable messages and shared strings between isolates (ADR-031, ADR-032).

### Added

- `daravel_test`: `TestClient` tests `web` routes as a browser meets them (#139). `client.browser()` keeps the cookies the application sets in a `CookieJar` (path matching, `Max-Age=0` and past `expires` delete, expiry measured with `Clock.now()`), sends them back, asks for HTML, and sends the `XSRF-TOKEN` cookie back as `X-XSRF-TOKEN` on writes, as Axios does, so `VerifyCsrfToken` accepts form posts (`browser(xsrf: false)` to test the `419`). Laravel's `followingRedirects()`, `withSession(data)`, `withCookie`/`withCookies` (encrypted with Laravel's `CookieValuePrefix`, as `EncryptCookies` expects) and `withUnencryptedCookie`/`withUnencryptedCookies` are there too. `TestResponse` gains Laravel's `assertSessionHas`, `assertSessionHasAll`, `assertSessionMissing`, `assertSessionHasInput`, `assertSessionHasErrors`, `assertSessionDoesntHaveErrors`, `assertSessionHasNoErrors`, `assertAuthenticated`/`assertGuest`/`assertAuthenticatedAs` (the user each guard had when the request ended), `assertRedirectContains`, `assertCookie`, `assertPlainCookie`, `assertCookieExpired`, `assertCookieNotExpired` and `assertCookieMissing`, plus `session` and `cookies`. All of it works over `TestTransport.socket` too. Guide: [Testing](docs/guide/testing.md#web-routes-cookies-session-and-csrf).
- `SessionStore` (core): the session as code outside `daravel_session` sees it, Laravel's `Illuminate\Contracts\Session\Session` reduced. `daravel_session`'s `Session` implements it, and `StartSessionMiddleware` puts the attributes of `request.attributes[SessionStore.seedAttribute]` (set in process only) into the session it starts, which is how `withSession` works without `daravel_test` depending on `daravel_session`.
- Content-Security-Policy: `SecurityHeadersMiddleware(contentSecurityPolicy: Csp()..defaultSrc(['self'])..scriptSrc(['self', Csp.nonce]))` sends the policy on HTML responses (a policy the handler set is kept). The `Csp` builder has a method per common directive plus `directive(name, sources)`, quotes keywords (`self`, `none`, `unsafe-inline`, `strict-dynamic`, `sha256-...`, `nonce-...`), writes hosts and schemes as given, and refuses a source with whitespace, `;`, `,` or a stray quote, so a configured value cannot add a directive. `Csp.strict()` is a starting point and `Csp(reportOnly: true)` sends `Content-Security-Policy-Report-Only`. `request.cspNonce` is the request's nonce (16 CSPRNG bytes, base64, made on first read), which a policy listing `Csp.nonce` sends as `'nonce-...'`, so nonce-carrying inline scripts and styles run without `'unsafe-inline'`. No policy is sent unless one is configured. Guide: [Security](docs/guide/security.md#content-security-policy), including the note that Chrome applies `form-action` to the redirects after a form `POST`.
- `package:daravel/html.dart`: every element helper takes `id`, `classes` and `attributes` (`link`, `meta`, `thead`, `tbody`, `br` and `hr` took none or only some; `strong`, `em`, `code`, `pre`, `li`, `tr`, `th`, `td`, `a`, `button`, `form`, `label` and `img` lacked `id`). `meta(name:, content:)` writes the common form. New helpers: `script(src:, content:, defer:, async:, module:, nonce:, integrity:, crossorigin:)`, `style(css, media:, nonce:)` and `jsonScript(data, id:)`; inline script and style content is written unescaped with every `</script` (`</style`) defused as `<\/script`, and `jsonScript` escapes `<`, `>`, `&`, U+2028 and U+2029 so no value closes the element (`RawTextNode`). `document(bodyAttributes:)` sets the attributes of `<body>` (`hx-headers`). htmx support: `request.isHtmx`, `isHtmxBoosted`, `htmxTarget` and `htmxTrigger` (extension `HtmxRequest`), and `htmxRedirect(request, url)`, which answers an htmx request with `HX-Redirect` instead of a redirect htmx would follow and swap in. Guide: [Responses](docs/guide/responses.md#html) gains a layout and slots pattern and an htmx section.
- Static files (#135): `ApplicationBuilder.withStatic('public', prefix: '/assets')` serves a directory, traversal-proof by construction: it is scanned at boot (dot files and symbolic links skipped) and a request is answered only by looking its path up among the files found, so `..`, `%2e%2e`, `%2f` or a backslash only miss. `asset('neo.css')` (`Assets.url`) gives `/assets/neo.css?v=<first 12 hex digits of the SHA-256>`; a request carrying the current version gets `Cache-Control: public, max-age=31536000, immutable`, any other `public, max-age=300` (`maxAge:`), with `ETag`/304 and ranges from `Response.file` and no `Content-Disposition`. `Assets.vite('resources/js/app.js')` (Laravel's `Vite::asset()`) reads `public/build/manifest.json` (or `.vite/manifest.json`), and the built files it lists are always immutable. With `APP_ENV=local` (`rescan:`) new and edited files are picked up without a restart. `dartisan static:hash` writes `.static-manifest.json` (version, size and modification time per file) so a production boot hashes only files changed since. `StaticFiles` and `StaticAssets` are the classes behind it, and `mimeTypeOf(name)` is the type `Response.file` sends. Guide: [Responses](docs/guide/responses.md#static-files).
- `daravel_session` and `daravel_redis`: the `redis` and `cache` session drivers (#133). `SESSION_DRIVER=redis`, registered by `withRedis()` next to `withSession()` (in either order), is Laravel's `redis` driver: the key `REDIS_PREFIX` + `CACHE_PREFIX` + session id holds the payload as `serialize()` writes a string, with `SESSION_LIFETIME` as its TTL, on the `default` Redis connection or the one `SESSION_CONNECTION` names (an unknown name stops the boot). A Laravel application with the same `APP_KEY`, cookie and prefixes shares the sessions; the value is PHP-serialized even with `REDIS_SERIALIZER=json`. `SESSION_DRIVER=cache` keeps sessions in any cache store, the one `SESSION_STORE` names (Laravel's `session.store`) or the default one. `CacheSessionHandler` is Laravel's `CacheBasedSessionHandler`, `SessionConfig.store` reads `SESSION_STORE`, and `redisSessionHandler` builds the Redis handler. `daravel_redis` now depends on `daravel_session`. Guide: [Sessions](docs/guide/sessions.md#redis-and-cache-drivers).
- Rate limits that fail closed: `Limit.failsClosed()` (`Limit(failClosed: true)`), `ThrottleMiddleware(failClosed: true)` and `ProcessRateLimitStore(failClosed: true)` refuse with `429` and `Retry-After: 1` an attempt the coordinator could not count (an error or a timeout, which flooding requests can cause), where rate limiting lets it through. Meant for limits that guard credentials (login, OTP, password reset), so that overloading the coordinator does not lift them. `RateLimitResult.degraded` marks an attempt the store could not count, and `RateLimiter.attempt(failClosed: true)` refuses it in any store. Rate limiting still fails open by default (ADR-003).
- Typed coordinator messages (ADR-031): `TypedCoordinatorService<M>` answers a typed message in `handleTyped`, and `TypedCoordinatorChannel.callTyped(service, message)` sends one; `LocalCoordinatorChannel` and `RemoteCoordinatorChannel` are both. `ProcessRateLimitStore` sends `RateLimitMessage` and `ProcessStore`'s locks (`acquireLock`, `releaseLock`, `forceReleaseLock`, `lockOwner`) send `LockMessage`, small `@pragma('vm:deeply-immutable')` objects that cross to the coordinator isolate by reference, where a map of arguments was copied entry by entry on every throttled request. `RateLimitGrant` (the answer to a lease) is deeply immutable too. Other cache operations and every other service stay maps, and `CoordinatorService.handle` keeps answering the same rate limit and lock operations as maps. A channel that implements only `CoordinatorChannel` (an application's own, a test double) keeps working: the stores fall back to `call` with the map of `RateLimitMessage.toArgs`/`LockMessage.toArgs`. Fail-open and fail-closed rate limiting behave as before.
- `CoordinatorMessage` (ADR-032): the marker interface of typed coordinator messages, which `RateLimitMessage`, `LockMessage` and `RateLimitGrant` implement. Its documentation states the contract: a `final` class annotated `@pragma('vm:deeply-immutable')` whose fields are only `int`, `double`, `bool`, `String` or other deeply-immutable classes, never a `List` or `Map`. Custom coordinator services may send deeply-immutable classes: such objects cross to the coordinator isolate by reference, so a `List` of 10 000 of them comes back in about 62–72 µs where plain objects take 1.4–1.9 ms (`bench/bin/isolate_payload.dart`, Windows AOT). A test checks that every `CoordinatorMessage` in the framework carries the pragma and that a batch crosses a `RemoteCoordinatorChannel` uncopied.
- `DB.transaction(fn, timeout:)` (`DatabaseManager.transaction`): a body still running when the timeout passes is given up, so a body waiting on a slow external call cannot hold its connection and empty the pool. Its transaction (or savepoint) rolls back inside the driver, the connection goes back to the pool, after-commit callbacks are dropped, and the call throws `TransactionTimeoutException` (a `TimeoutException`, never retried by `attempts`). The body's later queries throw it too instead of running, so nothing it does after the timeout reaches the database. A query already waiting in the database ends only when the database lets it go. Without `timeout` nothing changes.
- `dartisan doctor --production` advises on topology (ADR-031): with `APP_ISOLATES` of 4 or more in one process it notes that endpoints which allocate a lot per request scale better across processes and suggests `APP_PROCESSES` at half the cores with `APP_ISOLATES=2` behind the proxy (`bench/README.md` scenario 13: four isolates of one process 81–90 ms each, four processes 28 ms each); with `APP_PROCESSES` above 1 it reports, as an error, the `CACHE_STORE`, `CACHE_LIMITER` and `QUEUE_UNIQUE_LOCK_STORE` left on `memory`/`process` that `serve` refuses (ADR-027), unless `APP_PROCESSES_ALLOW_UNSHARED_STATE=true`; and with more than one isolate or process it notes `DART_VM_OPTIONS=--new_gen_semi_max_size=128` (81–90 ms to 70–77 ms in the same measurement) without setting it. Defaults, `serve` and the flags are unchanged.
- `daravel_excel`: `CsvSettings(escapeFormulas: true)` writes CSV text cells that a spreadsheet would run as a formula (starting with `=`, `+`, `-`, `@`, a tab or a carriage return) with a leading `'`, so a user-typed `=HYPERLINK(...)` or `=cmd|...` is shown, not run, when the export is opened (CWE-1236). Only `String` cells are touched, and plain numeric text (`-5`, `+6281234567`) is left alone. Off by default, as in Laravel Excel and PhpSpreadsheet. `escapeCsvFormula(text)` does the same for one value. XLSX is unaffected: its text cells are inline strings, never formulas.
- `BelongsTo`, `HasMany` and `HasOne` take `foreignKey` as optional and guess it as Laravel does: a `BelongsTo` from its relation name (`coAuthor` → `co_author_id`), a `HasMany`/`HasOne` from the parent's class name in `ModelDefinition.morphClass` and its primary key (`User` → `user_id`). An explicit `foreignKey` is used as before. `Relation.parentDefinition` is the definition a relation is declared on.
- `ModelDefinition(attributes:)`, Laravel's `protected $attributes`: default attribute values every new model starts with (not dirty), so `create()` inserts them and a non-null accessor reads them without `refresh()`. `dartisan model:sync` warns about a non-null column with a database default that the model does not declare there, whose accessor would throw on a freshly created model.
- `phpJsonDouble(double)`: a double as PHP's `json_encode` writes it (`serialize_precision = -1`, `zend_gcvt`), used by `PhpJsonEncoder` and `Response.json(phpCompatible: true)`.
- `Request.bodyInput()`: the body's fields as `all()` sees them, without the query (Laravel's `getInputSource()->all()`). A middleware that rebuilds the body with `replace()` starts from it, so the fields the client sent keep what `TrimStrings` made of them.
- `CachePrefixShaping`: a cache store that shapes the prefix its `CacheRepository` puts before keys, tag lists and lock names, as Laravel's stores own their prefix. `daravel_redis`'s `RedisStore` implements it (see Changed); `RedisStore(laravelCompat:)` fixes the layout instead of following `COMPAT_LARAVEL_VERSION`.
- The `array` cache store, Laravel's in-memory store and a common `CACHE_STORE` in `phpunit.xml` and `.env.testing`: `CACHE_STORE=array` and `Cache.store('array')` are the `memory` store (`CacheManager.arrayStore`), unless an application registers a store of that name. Before, `array` failed with "Cache store [array] is not defined".
- `TrimStringsMiddleware.defaultExcept`: the keys `TrimStringsMiddleware` leaves untrimmed by default, to extend rather than repeat (`{...TrimStringsMiddleware.defaultExcept, 'pin'}`).
- `RouteEntry.returnsFile(contentType:)`: documents a route that answers with a file (`Response.download`, `Excel.download`, a stream). OpenAPI describes a binary body of that type with `Content-Disposition`, and `dartisan client:flutter` generates a method returning `ApiFile` (the bytes, the file name from `Content-Disposition` and the content type) through the runtime's new `download()`, where it generated `Future<Object?>` and tried to decode JSON. A `raw` response with the new `RouteResponse.binarySchema` (or a non-JSON `RouteResponse.contentType`) is a file too (`RouteResponse.isFile`).
- `Rules.array([keys])` and `RuleBuilder.array` (`ArrayRule`): Laravel's `array` rule, a JSON array or object, with `array:name,email` limiting the keys (see Changed).
- Binary results from worker isolates without a second copy (ADR-031): `Concurrency.runBytes(tasks)` (`ComputePool.runBytes`) is `Concurrency.run` for tasks that return a `Uint8List` (a PDF, a CSV, an image, a compressed body), with the same order, failures, `concurrency` and `timeout`; a result of 32 KB or more crosses as a `TransferableTypedData`, copied once in the worker and moved to the caller, where `run` copies it. `Response.computed(bytes, contentType:)` sends such a result as the body; it is `Response.bytes`, which never copied either, documented for this use. `IsolatePayload.text` and `IsolatePayload.bytes` (`TextPayload`, `BytesPayload`) apply the same rule to an application's own ports: `toWire()` gives a `String`, a `Uint8List` or, from `IsolatePayload.transferThreshold` on, a `TransferableTypedData`, and `IsolatePayload.fromWire` materializes it, exactly once. Text, JSON included, stays a `String`, which the VM shares between isolates without copying.

### Changed

**Upgrading can change what an application sees:**

- `package:daravel/daravel.dart` and `package:daravel/http.dart` now export `Csp`, and `Request` gains `cspNonce` and `hasCspNonce`. An application that declares `Csp` hides it in its import (`hide Csp`); one with an extension adding `cspNonce` to `Request` sees the class member win. `SecurityHeadersMiddleware` sends no Content-Security-Policy unless `contentSecurityPolicy` is given.
- `package:daravel/html.dart` now exports `script`, `style`, `jsonScript`, `RawTextNode`, `htmxRedirect` and the `HtmxRequest` extension, and `package:daravel/daravel.dart` and `package:daravel/foundation.dart` export `escapeHtml` from its new shared declaration (the same name as before). An application that declares one of the new names hides it in its import of `package:daravel/html.dart`. `escapeHtml` in mail and notification HTML now writes `'` as `&#039;`, as `escapeHtml` in `html.dart` and Laravel's `e()` do, where it wrote `&#39;`; both mean the same character.
- `package:daravel/daravel.dart` now exports `IsolatePayload`, `TextPayload` and `BytesPayload` (ADR-031). An application that declares one of those names hides it in its import of `package:daravel/daravel.dart`.
- `package:daravel/daravel.dart` now exports `TransactionTimeoutException` (`DB.transaction(timeout:)`). An application that declares that name hides it in its import of `package:daravel/daravel.dart`. Transactions without `timeout` behave as before.
- `package:daravel/daravel.dart` now exports `asset`, `Assets`, `StaticFiles`, `StaticFile`, `StaticAssets` and `mimeTypeOf` (static files). An application that declares one of these names hides it in its import of `package:daravel/daravel.dart`.
- `Response.file`, `Response.download` and `Storage.response` pin the types browsers check rather than taking them from `package:mime`: `.js`/`.mjs` are `text/javascript`, `.map` is `application/json` (was `application/octet-stream`), and `.css`, `.json`, `.wasm`, `.svg`, `.woff2`, `.woff`, `.ttf`, `.otf` and `.webmanifest` keep their standard types whatever the `mime` version.
- `TypedCoordinatorService`, `TypedCoordinatorChannel`, `RateLimitMessage` and `LockMessage` are new exports: an application that declares one of those names hides it in its import of `package:daravel/daravel.dart`. `CoordinatorChannel` gains no member, so an application's own channel compiles as before. `CoordinatorRequest.args` is typed `Object` (a `Map<String, Object?>`, or a typed message); code that read it as a map casts it first. `RateLimitService` and `ProcessCacheService` now implement `TypedCoordinatorService`, which still implements `CoordinatorService`.
- `CoordinatorMessage` is a new export: an application that declares that name hides it in its import of `package:daravel/daravel.dart`.
- `daravel_session` now exports `CacheSessionHandler` and `daravel_redis` exports `redisSessionHandler` (`SESSION_DRIVER=cache` and `redis`). An application that declares one of those names hides it in its import of `package:daravel_session/daravel_session.dart` or `package:daravel_redis/daravel_redis.dart`. An application that registers its own `redis` driver with `SessionManager.extend` keeps it: `withRedis()` adds the built-in one when the manager is created, before application code can reach the manager. `daravel_redis` depends on `daravel_session`.
- `daravel_excel` now exports `escapeCsvFormula`. An application that declares that name and imports `package:daravel_excel/daravel_excel.dart` hides it in that import (`hide escapeCsvFormula`). CSV output is unchanged unless `escapeFormulas` is turned on.
- `daravel_redis`: with `COMPAT_LARAVEL_VERSION` 10 or lower, a non-empty `CACHE_PREFIX` is followed by `:` in Redis keys (`<REDIS_PREFIX><CACHE_PREFIX>:<key>`), as Laravel's `RedisStore::setPrefix` wrote them up to 10.x (laravel/framework v9.52.16 and v10.48.29; from v11.0.0 the prefix is kept as given, which stays the layout for 11 and later). Before, Daravel wrote the 11+ layout for every version, so an application sharing its Redis cache with a Laravel 10 application did not find Laravel's entries (sessions, counts, locks). Such an application now does. An application on 10 or lower that does not share its cache sees its old Redis entries as missing once after upgrading; they expire as before. The `tiered` store keeps its own layout.
- `PhpJsonEncoder` (and so `Response.encodePhpJson` and `Response.json(phpCompatible: true)`) writes doubles as PHP's `json_encode` does, checked against PHP 8.3.36: a whole double without its fraction (`2.0` is now `2`, `0.0` is `0`, `-0.0` is `-0`), and the E-style below 0.0001 or from 1e17 on (`1.0e-5`, `1.0e+17`, where it wrote `0.00001` and `100000000000000000.0`). Integers are unchanged. A client that told integers from doubles by the `.0` in a PHP-compatible answer sees whole doubles as integers now, as it would from Laravel. `phpJsonDouble` is a new export: an application that declares that name hides it in its import of `package:daravel/daravel.dart`.
- Input transformers (`TrimStringsMiddleware`, `ConvertEmptyStringsToNullMiddleware`, `Request.addInputTransformer`) apply as in Laravel's `TransformsRequest`, checked against laravel/framework 10.48.29:
  - **Only to input as the client sent it.** Fields that `Request.merge` or `Request.replace` set afterwards are kept as given: `' x '` stays `' x '` and `''` stays `''`, where they were trimmed and turned into `null` before. Only a transformer registered after the merge still sees them. This matters to a middleware that merges input it produced, such as a payload decryption. An application that relied on its merged values being trimmed or converted trims them before `merge`.
  - `daravel_teobiefy`'s `teobiefy`, `teobiefy.aes` and profile middleware build the decrypted body from `Request.bodyInput()`, so the clear fields beside `data_enc` keep what the transformers made of them and the decrypted fields arrive as the client encrypted them.
  - **`current_password` is no longer trimmed** by default, as in Laravel's `TrimStrings` (`$except` is `current_password`, `password`, `password_confirmation` in laravel/framework 10, 11 and 12). Before, a current password sent with surrounding spaces was trimmed and then failed `Hash.check` against a password that kept them.
  - **The key is the dotted path.** A transformer now receives `user.password` or `tags.0`, not `password` or `tags`, so `TrimStringsMiddleware(except:)` names a path. The default `{'password', 'password_confirmation'}` no longer leaves a nested `user.password` untrimmed (Laravel trims it too); list it as `user.password` to keep it as sent.
- `dartisan make:model` (with its `--migration`) and `make:controller --model` guess the table and route name with `Str.plural`, as Laravel's `Str::plural` does, instead of adding `s`/`es`: `Stimulus` gets `stimuli`, `Person` `people`, `Quiz` `quizzes`. Only new files are affected; pass `--table` to keep another name. `Str.plural` and `Str.singular` know the Latin plurals doctrine/inflector applies (`stimulus`/`stimuli`, `curriculum`/`curricula`, `syllabus`/`syllabi`, `radius`/`radii`, `focus`/`foci` and the like).
- `SessionStore` is a new export of `package:daravel/daravel.dart` (and `package:daravel/http.dart`), and `CookieJar` and `ResponseCookie` (plus the top-level `encryptCookieValue`) are new exports of `package:daravel_test/daravel_test.dart`: an application that declares one of those names hides it in its import. `TestResponse.assertRedirect(location)` now compares absolute URLs, as Laravel's `assertLocation` does, so `/login` matches a `Location` of `http://localhost/login`; it failed before. A `TestClient` over the socket transport no longer sends the `x-daravel-test-actor` header to the application: the harness removes its own header before the application sees the request.
- `dartisan client:flutter`: a response property declared `oneOf: [X, {type: null}]` (or `anyOf`), the usual JSON Schema for "X or null", is typed `X?` and decoded with `X.fromJson` (#112). It was `Object?`, so the application decoded it by hand. **Behaviour change** after regenerating a client: code that still wraps such a field in `X.fromJson(...)` (`MembershipSession.fromJson(signIn.session)`) compiles as before, since `fromJson` takes `Object?`, but would fail at runtime with `FormatException: Expected a JSON object, got X`. So that it keeps working, the generated `X.fromJson` now returns its argument when it already is an `X`; migrate by dropping the `X.fromJson(...)` around such fields (`signIn.session` is the `MembershipSession?`).
- `dartisan lint` prints each finding as `dart analyze` does, `  info - lib/app/web/assets.dart:14:18 - <message> - no_mutable_static_in_app`, then `1 issue found.` or `N issues found.` (it printed `path:line:column  rule  message` and `N issue(s).`), so a script that parses the plain output needs the new layout; `--json` is unchanged and any finding still exits 1. `formatLintIssue` (`package:dartisan_cli`) formats one finding; an application that declares that name and imports `package:dartisan_cli/dartisan_cli.dart` hides it in that import.
- Under a supervisor, each worker sends its metrics snapshot (every second) and its `WorkerReports` reports (Pulse) to the coordinator as JSON text, which the VM shares between isolates, where it sent maps the supervisor's event loop deep-copied on every message (ADR-031). The coordinator keeps the text and decodes it where it is read: `/metrics` merges the snapshots on a scrape, `WorkerReports.collect` decodes each report. `/metrics` output, metric names and labels, Pulse and `coordinator:stats` are unchanged. A report `WorkerReports.collect` returns is now the JSON-decoded value (the same contents, with `List<dynamic>` and `Map<String, dynamic>` for lists and maps); a number, boolean or `null`, and a value JSON cannot hold (a NaN, a custom sendable object), still travel as they are.
- The `process` cache store sends values to the coordinator as JSON strings, which the VM shares between the isolates of a process, instead of maps and lists, which it copies on the coordinator's event loop (9 ms per MB measured, during which every worker waits). Numbers, booleans and null cross as they are, so `increment` still works on a stored number, and a value JSON cannot encode (a `DateTime`) still crosses as the object. `ProcessStore.encodeWire`/`decodeWire` expose the wire form; the near cache (`CACHE_PROCESS_L1_TTL`) keeps it and decodes per read, so callers still get their own copy. The coordinator's port is a `RawReceivePort`. Guide: [Operations](docs/guide/operations.md#isolates); `bench/bin/isolate_payload.dart` reproduces the measurement.

### Fixed

- A file importing both `package:daravel/daravel.dart` and `package:daravel/html.dart` can call `escapeHtml`: both libraries export one shared declaration, where each declared its own and the call failed to compile as an ambiguous import (`hide escapeHtml` is no longer needed).
- `daravel_session`: the `database` driver no longer answers 500 with a duplicate key on MySQL and MariaDB when a request leaves the session unchanged within the same second (#132). The handler inserted the row whenever the UPDATE reported 0 rows, but MySQL and MariaDB count changed rows, not matched ones. As Laravel's `DatabaseSessionHandler` does, it now remembers whether `read()` found the row and updates it if so, inserts it otherwise, and updates instead when the insert meets a row another request created meanwhile (`UniqueConstraintViolationException`). A write without a read on the same handler looks the row up first.
- `dartisan db:seed --class=X` with a seeder that `bootstrap/seeders.dart` does not list prints `Seeder X is not registered in bootstrap/seeders.dart. Registered: DatabaseSeeder, ...` on stderr and exits 1, where a seeder written by hand but not registered looked as if it had run. `make:seeder` registers the seeders it writes.
- `dartisan e2e:install` writes `"@playwright/test": "~1.64.1"` instead of `^1.48.0`: npm lists `@playwright/test` 1.65.0 while `playwright-core` 1.65.0 is missing from the registry, so `npm install` failed with `ETARGET`. The starter's e2e suite carries the same pin.
- Sanctum tokens with a UUID or ULID id: `TokenGuard(keyType:)` and `AuthManager.token(..., keyType:)` take `KeyType.uuid` or `KeyType.ulid` for a tokens table whose Laravel `PersonalAccessToken` model uses `HasUuids` or `HasUlids`. Such a guard issues tokens with a generated UUID/ULID id (`insertGetId` read back nothing) and finds `<uuid>|<secret>` tokens, which `int.tryParse` refused before, so a Laravel-issued token did not authenticate. A token id that cannot be the table's key (text for an integer key, an integer or a malformed id for a UUID/ULID key) is a miss before any query, so PostgreSQL never compares text with a `bigint` column (an error, so a 500, not a 401). The default stays `KeyType.autoInt`; other key types are refused when the guard is made.
- `FileStore` (`CACHE_STORE=file`, and the `file` store some packages pick for state shared between processes, such as `daravel_permission`'s cache version) no longer fails a write with `PathNotFoundException: Cannot rename file` when processes share its directory, as `dart test` does with one process per test file. Two writes made in the same millisecond took the same temporary file, and a write whose directory another process flushed was not made again. `increment`, `decrement`, `add` and `touch` are now atomic across processes (an OS lock per key) and across the calls of one isolate, so no count is lost; Laravel takes `LOCK_EX` for the same reason.
- `daravel_redis`: a blocking command sent with `RedisClient.command` or `Redis.command` (`BLPOP`, `BRPOP`, `BRPOPLPUSH`, `BLMOVE`, `BZPOPMIN`, `BZPOPMAX`, `BLMPOP`, `BZMPOP`, `XREAD`/`XREADGROUP` with `BLOCK`, `WAIT`, `WAITAOF`) runs on a connection of its own and waits as long as it blocks plus `REDIS_COMMAND_TIMEOUT` (without limit for a timeout of `0`), as the guide said. Before, it went through the shared connection with the 1 s command timeout, so `XREADGROUP … BLOCK 2000` failed with `RedisConnectionException: XREADGROUP timed out after 1000ms`, closed the connection, and held up the commands pipelined behind it. `RedisClient.blockingTimeout(args)` tells how long a command blocks.
- The query builder validates the structural SQL arguments `operator` and `boolean` in every clause: `boolean` must be `AND` or `OR` (any case) on every `where*`, `having` and join condition, and `whereColumn`, `having`/`orHaving`, `join`/`leftJoin`/`rightJoin`, `joinSub` and `JoinBuilder.on`/`orOn`/`where` take only the operators `where` already accepted (`!=` is written `<>`). Anything else throws an `ArgumentError` before SQL is built, and the grammars write only those tokens, even for a hand-built `QueryAst`; before, both arguments went into the SQL text as given. An application that passed another operator to one of those methods (`<=>`, `@>`, `SIMILAR TO`) gets the `ArgumentError` now and writes that condition with `whereRaw`/`havingRaw`.
- `migrate:fresh` (`SchemaBuilder.dropAllTables`) on MySQL and MariaDB drops tables that foreign keys join, where it stopped at the first parent table (`1451 Cannot delete or update a parent row`). It drops the database's foreign keys first, then every table in one `DROP TABLE`, so no pooled connection is left with `FOREIGN_KEY_CHECKS = 0`. `SchemaBuilder.getTables` on MySQL and MariaDB no longer lists views, as Laravel's `Schema::getTables`.
- A composite primary key (`table.primary([...])`) on MySQL and MariaDB is written `PRIMARY KEY (...)` without a name, as Laravel's `MySqlGrammar` writes it. MySQL names every primary key `PRIMARY` but still refused a `<table>_<columns>_primary` name longer than 64 characters (`1059 Identifier name is too long`), leaving the migration half done. `SchemaGrammar.compilePrimaryKey` writes the constraint, so a dialect can change it.
- Timestamps that MySQL and MariaDB give as `Y-m-d H:i:s` text are read as UTC, the zone Daravel writes them in, by `parseDbDateTime` (personal access tokens' `expires_at`, `last_used_at` and `created_at`), by failed jobs' `failed_at` and by `daravel_payments`' `PaymentRecord.paidAt`. They were read in the process's local zone, so with `TZ` other than UTC every token with an expiry was refused as expired (8 hours early at UTC+8). The ORM's `Cast.dateTime` already read them as UTC. CI runs the MySQL tests again with `TZ=Asia/Makassar`.
- `mcp:serve` `db_query` on MySQL and MariaDB runs in a `START TRANSACTION READ ONLY` transaction, as it already did read-only on SQLite and PostgreSQL. A `SELECT` could take row locks (`FOR UPDATE`), advance a MariaDB sequence (`NEXTVAL`) or call a function that writes; the server now refuses those. `GET_LOCK` is refused, since a named lock outlives the rollback, and every query stops after 10 seconds (`MAX_EXECUTION_TIME` on MySQL, `max_statement_time` on MariaDB, `statement_timeout` on PostgreSQL; `readOnlySelect(timeout:)`).
- `dartisan model:sync` writes `Object?` for a `decimal`/`numeric` column without a cast on MySQL, MariaDB and SQLite, with a hint to add `Cast.decimalString(N)` (Laravel's `decimal:N`, N read from the column). It wrote `String?`, which held on MySQL (a string) but threw a `TypeError` on SQLite (a number), for example in tests. Columns with `Cast.decimalString` stay `String`; PostgreSQL's `numeric` stays `String`.
- `dartisan model:sync` fills an empty `// <dartisan:statics>` region with the query shortcuts `make:model` writes (`query`, `find`, `findOrFail`, `create`, `all`, `where`). A region that holds anything is left alone.
- The `array` rule accepts a JSON object as well as a JSON array, as Laravel's `array` accepts any PHP array, and `array:name,email` limits the keys (laravel/framework `validateArray`). Before, `array` was list-only, so a request that a Laravel application accepts (`'stem' => 'required|array'` with an object) failed with 422. The `list` rule string stays list-only and now reports Laravel's `list` message (`The :attribute field must be a list.`), as does `Rules.list()`; it reported the `array` message before. In the JSON Schema of `rulesToJsonSchema` and OpenAPI, an `array` field without `field.*` or `field.key` rules is `"type": ["array", "object"]` (it was `"array"`), and `dartisan client:flutter` types it `Object?` (it was `List<Object?>`); write `list` for a list-only field. `ArrayRule` is a new export: an application that declares that name hides it in its import of `package:daravel/daravel.dart`.
- `dartisan client:flutter`: the page of a `.paginated` route is `ApiPage<T>` (it was `Page<T>`), so a Flutter file importing both the client and `package:flutter/widgets.dart` (or `material.dart`) no longer needs `hide Page`. `Page<T>` stays as a deprecated typedef of `ApiPage<T>` in the regenerated runtime, so code written against the old name compiles with a deprecation hint; files that hid Flutter's `Page` keep working.
- `Model.toJson` serializes models, dates and enums inside any collection, at any depth: a `Set<Model>`, an `Iterable<Model>` that is not a `List`, a `List<dynamic>` and a string-keyed `Map` (in a relation, an attribute or an appended value) give each model's `toJson`, as Laravel's `toArray` does. Before, only a `List<Model>` was serialized, and other collections went to `jsonEncode` as they were, so a nested model failed to encode or skipped its hidden attributes. A `JsonSerializable` that is not a model keeps its own `toJson`, even when it is an `Iterable`.

## 1.25.0

For an application that moves from Laravel route by route. `withUpstream` now forwards forms, uploads, the client's method and its `Host` as sent, and its shadow replay can compare a moved route's answer byte for byte. JWTs are shared with tymon/jwt-auth's `lock_subject`, and Sanctum tokens and JWTs are checked both ways beside real Laravel 8 to 13. Two security checks are new: inline JavaScript built from values (`daravel_lints`), and scripts from another origin without Subresource Integrity (`security:audit`).

### Added

- `daravel_teobiefy`: `TeobiefyCrypto.clientSessionKeys`, libsodium's `crypto_kx_client_session_keys` (the client's rx and tx, crossed with `serverSessionKeys`; a low-order point is refused), for a client of a teobiefy API such as a tool that compares two backends. Checked against a vector made by PHP's sodium. `zstdDecompress` (with `ZstdFormatException` and `ZstdTooLargeException`) is exported, to open the `data` a PHP side compressed with `zstd_compress`.
- `withUpstream(shadowCompare: ShadowCompare.bytes)` (`UPSTREAM_SHADOW_COMPARE=bytes`): the shadow replay compares a moved route's status, headers and body with Laravel's byte for byte, not only the shape of its JSON. `Date`, `Server`, `Content-Length`, the connection headers and `X-Request-Id` are left out (`shadowIgnoreHeaders`); Laravel's session and CSRF cookies are compared by name and attributes; `shadowNormalizeKeys` blanks, per request, JSON values that differ by design on both sides. A drift is `header` or `body` and carries counts and lengths, never values. `ShadowAnswer.headers` holds the upstream's headers. The default stays `ShadowCompare.shape`.
- `daravel_lints`: `no_inline_js_interpolation` reports a value interpolated into an inline `on*=` event handler of generated HTML, a Dart value (`$name`) or a JavaScript template value (`\${name}`) in a page's script. HTML escaping does not make that safe, because the browser decodes the entities before it runs the attribute as JavaScript; the finding points at the value and suggests a `data-*` attribute with `addEventListener`. `LintRule.checkAt` lets a rule report an offset inside a node, and defaults to `check`.
- `dartisan security:audit`: check `DARAVEL-SEC-014` reports scripts and module preloads (medium) and stylesheets (low) loaded from another origin, such as a CDN, without an `integrity` hash; Google Fonts CSS, which differs per browser, is exempt.
- JWT tokens shared with tymon/jwt-auth, Laravel's `jwt` guard with `lock_subject`: `JWT_SUBJECT_CLASS` (for example `App\Models\User`) makes issued tokens carry `prv` (the sha1 of that class name, as tymon computes it), `nbf` and `iss` (`JWT_ISSUER_CLAIM`, written but not checked), and refuses a token whose `prv` names another class. Unset, tokens are as before. With `JWT_TTL` in minutes and `JWT_LEEWAY=0`, a token issued by tymon/jwt-auth 2.2.1 signs the same user in, and the other way round (conformance test with a token tymon issued).
- `bench/interop/laravel_matrix.sh` also checks tokens beside real Laravel 8 to 13: Sanctum personal access tokens both ways with Sanctum's own guard (abilities, `last_used_at`, and from Laravel 10 on `expires_at`), and tymon/jwt-auth JWTs both ways with `lock_subject` (valid, expired, and a `prv` for another class refused on both sides) on every version tymon ^2.2 installs on (9 to 13).

### Changed

**Upgrading can change what an application sees:**

- `daravel_teobiefy` now exports `zstdDecompress`, `ZstdFormatException` and `ZstdTooLargeException`. An application that declares one of those names and imports `package:daravel_teobiefy/daravel_teobiefy.dart` hides it in that import (`hide zstdDecompress`).

### Fixed

- `withUpstream(shadowCompare: ShadowCompare.bytes)`: a session cookie named after the application (`Str::slug(APP_NAME, '_').'_session'`, not only `laravel_session`) is compared by shape, not reported as a drift on every answer that sets it. `ShadowParityRunner.defaultFreshCookies` is now `XSRF-TOKEN` and `*_session` (an entry starting with `*` matches a name suffix), and `withUpstream(shadowFreshCookies:)` or `UPSTREAM_SHADOW_FRESH_COOKIES` replaces the list.
- `apps/virtual_classroom`: the lesson cards bind their buttons with `addEventListener` instead of inline `onclick` code, so a lesson name with a quote can no longer run script in a student's browser (the browser decodes HTML entities in an attribute before it parses the JavaScript). A LiveKit room that cannot be opened is an error everywhere except `local` and `testing` (it was hidden in `staging`), the livekit-client script from the CDN carries a Subresource Integrity hash, the "saving" label is translated, and the meeting resource no longer repeats its `id` as `uuid`.
- `withUpstream`: a form or multipart `POST` that no route matches reaches the upstream with its body. The method override read such a body to look for `_method` and, for multipart, consumed the stream, so uploads through the proxy came back as 502. With an upstream, the override now keeps the raw bytes first, which buffers a form or multipart `POST` in memory in full (up to `HTTP_MAX_BODY`); an application that proxies large uploads sets `middleware.methodOverride = false` so they stream through unread. The proxy now forwards the method the client sent (`Request.originalMethod`), not a `_method` override, because PHP parses a multipart body only for a `POST`; Daravel's own routes still take the override. With `preserveHost`, the client's `Host` is sent as it came: a `Host` without a port used to reach the upstream with the upstream's port, which changed Laravel's `fullUrl()` and every URL it generates.
- `registry_entry_missing` (`dartisan lint`) no longer reports a seeder that a registered seeder imports and runs itself, as Laravel's `DatabaseSeeder` does with `$this->call()`. Jobs, models, migrations and commands still need their own registry entry.

## 1.24.1

A documentation release: the API docs on pub.dev, the guide and the example applications; no change to the API.

### Added

- Example application `apps/cat_exam_demo`: a computer-assisted test with a device lock per candidate, answers saved as they are chosen, a server-side timer, instant scoring and ranking, in English and Indonesian (`withTranslations`, `SetLocaleMiddleware`).
- Every example application has a README with requirements, setup, how to run and try it, tests, troubleshooting, and how to use it outside the repository; `apps/daravel_starter` has its first.
- `apps/virtual_classroom` has a browser page that joins real LiveKit rooms (camera, microphone, raised hands, the teacher muting everyone), in English and Indonesian; its demo routes answer only while `APP_ENV` is `local` or `testing`, and its README says how to run LiveKit and Google Calendar outside the repository.

### Changed

- Documentation: every public API element of every package has a doc comment (pana: 47 % to 99 % for `daravel`), and each guide page ends with the Laravel equivalents it supports and the API to look up, so the guide names every entry of the parity table.

## 1.24.0

### Added

- Pulse: `PULSE_PARITY_DRIFT_THRESHOLD` marks a route on the Shadow parity drift card once it drifts that often in the period.
- `daravel_scout`: Laravel Scout on the database engine, with `LIKE` and full text search on the model's table, and `semantic()` and `hybrid()` on PostgreSQL with pgvector or MariaDB.
- Example application `apps/websocket_demo`: a chat with rooms over WebSockets and `Broadcast`, an echo socket, and an HTTP endpoint that pushes to the sockets.

## 1.23.1

A fix for applications that share their database with Laravel.

### Fixed

- The database cache store read a value Laravel wrote to a shared table as an error. It is now a cache miss.

## 1.23.0

The parts of Laravel 13 a growing application reaches for: JSON:API resources, checked byte for byte against a real Laravel 13, `Concurrency` on warm isolates, `Process`, vector columns on PostgreSQL and MariaDB, debounced jobs, and automatic eager loading. For a migration: shadow parity compares a moved route with Laravel under real traffic, and `LegacyKey` makes `MAX(id) + 1` safe with parallel writers. Tested beside real Laravel 8 to 13.

**Upgrading can change what an application sees:**

- A `mariadb` connection now has `SqlDialect.mariadb`, not `mysql`. Code that compares `dialect == .mysql` should use `dialect.isMySqlFamily`, and an exhaustive `switch` on `SqlDialect` or on `Cast`, which gained `VectorCast`, stops compiling until it names the new case.
- A job whose model is gone now fails at once, as in Laravel, instead of using up its tries. `deleteWhenMissingModels` drops it instead.
- `TransactionCommitted` and `TransactionRolledBack` are now sent. They existed before and never fired, so a listener registered long ago starts to run.
- `package:daravel/daravel.dart` now exports `LegacyKey`. An application that declares its own `LegacyKey` stops compiling wherever a file imports both (`'LegacyKey' is imported from both ...`). Move to the framework's class (`LegacyKey.next(table)` and `LegacyKey.insert(table, values)`), or keep yours with `import 'package:daravel/daravel.dart' hide LegacyKey;`.

### Added

- Transaction events: `DB.listenTransactions`, with `poolWait` and `depth`, forwarded as `TransactionBeginning`, `TransactionCommitted` and `TransactionRolledBack`, of which the last two existed and were never sent. Pulse counts a transaction's wait for a connection.
- `DaravelUri`: Laravel's fluent `Uri`, with PHP's reading and writing of the query.
- `package:daravel/process.dart`: `Process.run`, `pipe`, `pool` and `fake`.
- `Queue.route`: where a job type goes, in one place, and `withoutDelay()` on a dispatch.
- `deleteWhenMissingModels`. A missing model now fails a job at once, as in Laravel, instead of using up its tries.
- `debounceFor`, `debounceMaxWait` and `debounceId`: only the last dispatch of a burst runs.
- `Model.automaticallyEagerLoad` and `withRelationshipAutoloading()`: the models of a result load their relations together, through `load` and `loadMissing`, and so do the models those bring in. An N+1 loop becomes one query per relation, and a later `load` still refreshes.
- `Concurrency`: `run`, `defer`, `runIfLarge`, `sync` and `fake`, on a pool of warm worker isolates, also as `package:daravel/concurrency.dart`.
- `JsonApiResource` and `JsonApiCollection`: Laravel 13's JSON:API v1.1 shape, with `?fields[type]=` and `?include=`. The kernel awaits a new `PreparedResponsable.prepare` before `toResponse`, so a route that returns a resource loads what the query asks for.
- `JsonSchema`: a typed builder for JSON Schema documents, like `Illuminate\JsonSchema`.
- Shadow parity: `withUpstream(shadowSampleRate:)` replays a sample of the `GET` and `HEAD` requests Daravel answers to the upstream, after the response, and reports differences in status, content type and JSON shape to the log and `ShadowParityDrift`.
- pgvector: `Blueprint.vector`, `tsvector` and `vectorIndex`, `Schema.ensureVectorExtensionExists`, `Cast.vector`, `whereVectorSimilarTo`, `whereVectorDistanceLessThan`, `orderByVectorDistance` and `selectVectorDistance`. On PostgreSQL and MariaDB 11.7 or newer; MySQL gets the column. MariaDB reads a vector through `selectVector`.
- Pulse: a Shadow parity drift card, from `ShadowParityDrift`.
- `LegacyKey`: keys for tables without a sequence, where Laravel code writes `MAX(id) + 1`, safe with parallel writers on PostgreSQL, MySQL, MariaDB and SQLite.

## 1.22.0

What most Laravel applications reach for every day: forms that post `_method`, validation that redirects back, file downloads with `Range`, 22 more validation rules, route model binding with scoping, subdomains, JSON columns, and helpers on relations. `daravel_pulse` now shows N+1 queries and connection waits, and `daravel_teobiefy` reads the Zstandard frames real clients send.

**Upgrading can change what an application sees:**

- A failed validation in the `web` group redirects back, unless the client expects JSON. `Request.expectsJson` follows Laravel: an XHR that asks for HTML is not JSON.
- `_method` is on by default. A POST route that streams a form body needs `middleware.methodOverride = false`.
- Since 1.21.1 a `try` around `next` catches nothing, in any middleware. Read the new `response.exception` instead.
- `whereJsonContains` sends JSON on MySQL and PostgreSQL. Code that encoded the value itself now encodes it twice.
- `UniqueRule.ignore` is a method; the field is `ignored`.

### Fixed

- PostgreSQL `inet`, `cidr`, `macaddr` and `macaddr8` columns came back as undecoded bytes, so comparing one with `request.ip` always failed. They are text now, as PostgreSQL prints them, and `model:sync` types them as `String`.
- Validation errors in a JSON session use the bag format of Laravel 13 (`{default: {format, messages}}`), which its `Store::marshalErrors` needs.
- `whereJsonContains` sends a JSON document on MySQL and PostgreSQL, as Laravel: a plain number or string failed there.
- `daravel_teobiefy`: refusals (406, 409, 413, 401) follow the route's response profile, as upstream's `api()->response()`.
- `accepted_if` and `declined_if`: with a `boolean` rule on the other attribute, `true` and `false` compare as booleans, and `:other` uses the custom attribute names.

### Changed

- `Request.expectsJson` follows Laravel: an XHR that asks for HTML, as an Inertia visit does, no longer counts as JSON.

### Added

- `Response.exception`, Laravel's `$response->exception`: since 1.21.1 an exception no longer passes through `next`, so a `try` around `next` catches nothing, not only in transaction middleware. A middleware reads it here instead.
- `DB.transaction(attempts: n)` waits a short random time between retries (decorrelated jitter, 2 to 250 ms), so isolates that collided do not collide again. Frozen test clocks retry at once.
- `QueryExecuted.poolWait`: the time a query waited for a connection, apart from `time`. PostgreSQL and MySQL measure it while a listener is registered.
- `daravel_pulse`: cards for N+1 queries and query storms (`PULSE_N_PLUS_ONE_THRESHOLD`, `PULSE_QUERY_STORM_THRESHOLD`) and for connection waits (`PULSE_POOL_WAIT_THRESHOLD`).
- `dartisan route:diff --by-prefix`: progress per module.
- `Cache.touch(key, ttl)`, `WithoutOverlapping(key, shared: true)` and `ReadThroughDisk`, Laravel's read-through filesystem for moving files to a new disk gradually.
- Subdomain routing: `router.group(domain: '{tenant}.example.com')` and `.domain()`, with routes of the same path on different hosts, host parameters before path ones, and `router.url()` on that host. `Request.fake` now takes its host from a `host` header, as the socket path does.
- Route model binding: `router.bindModel('post', Post.definition)`, `{post:slug}`, `.scopeBindings()` (implied by a custom column, as in Laravel) so another owner's row is a 404, `.withoutScopedBindings()`, `.withTrashed()` and `.missing()`. It is explicit: a Dart handler has no parameter types to tell a model from an id.
- ORM helpers: `BelongsTo.withDefault`, `HasOne.latestOfMany`, `oldestOfMany` and `ofMany` (one query when eager loading), `syncWithoutDetaching`, `toggle` and `updateExistingPivot`, on `BelongsToMany` and on the model, `updateQuietly`, `deleteQuietly`, `namedGlobalScopes` with `withoutGlobalScope(name)`, and `QueryBuilder.whereNone`.
- JSON columns: `where('meta->lang', 'id')`, `orderBy` and `update({'meta->lang': 'en'})` on SQLite, PostgreSQL and MySQL, as Laravel compiles them. Writing a nested path needs its parent on PostgreSQL and MySQL, as in Laravel; SQLite creates it. Tested live on SQLite, PostgreSQL, MySQL 8.4 and MariaDB 11.
- `withoutMiddleware(['csrf'])` takes aliases, groups, types and instances, also those from an outer group.
- 22 validation rules: `gt`, `gte`, `lt`, `lte`, `decimal`, `multiple_of`, `min_digits`, `max_digits`, `date_equals`, `timezone`, `required_with_all`, `required_without_all`, `required_if_accepted`, `present_if`, `prohibited_if`, `prohibited_unless`, `prohibits`, and the `exclude` family, which leaves attributes out of `validated()`. Numbers compare as exact decimals. `timezone` also accepts old IANA aliases, and not `per_country`.
- `Rules.enum_`, and `Rules.unique(...).ignore(id)`, `.where(...)` and `Rules.exists(...).where(...)`. Both rules accept `schema.table`, which failed with an `ArgumentError`.
- `Response.download`, `Response.file`, `Storage.download` and `Storage.response`, with RFC 6266 file names, `ETag`, and `Range` (206) when given the request. `deleteFileAfterSend` removes a temporary file once it was sent. Several ranges in one request get the whole file.
- `_method` and `X-HTTP-Method-Override` turn a POST into PUT, PATCH or DELETE, on by default as in Laravel; only form bodies are read. `Request.originalMethod` keeps the verb on the wire.
- A failed validation in the `web` group redirects browsers and Inertia back, with errors and old input flashed (`session.errors`, `session.old`); clients expecting JSON keep the 422. `Response.back` ignores a foreign `Referer`.
- Remember-me cookies in `SessionGuard`: `attempt(..., remember: true)` and `login(user, remember: true)` write Laravel's `remember_web_<sha1>` cookie, and either side can log in from the other's.
- Payload profiles of teobiefy-laravel-api-response 0.3 in `daravel_teobiefy`: `withTeobiefyProfiles()` and the `teobiefy.profile` middleware (route patterns, XChaCha20, ChaCha20 and AES-256-GCM with key ids, HMAC-SHA256, replay protection). Responses are raw frames; requests may use any frame `ext-zstd` writes, read by a pure Dart decoder.
- `ModelQuery.orderByRaw`, `KeyType.manualInt` (Laravel's `$incrementing = false` on an integer key), `Request.inputSync` for model scopes, and `Clock.nowIn('Asia/Makassar')`.

## 1.21.1

Four fixes in the core. The first matters most: a handler that failed lost its session changes, so a logout followed by an error left the user logged in.

**Three of them can change what an application sees:** a middleware that wraps `next` in a transaction now gets a response instead of an exception, so it does not roll back on its own, as in Laravel; `insert()` refuses a row with other columns than the first, where a missing one used to write `NULL`; `Cast.integer` gives `0` for text with no leading number, not `null`.

### Fixed

- An exception skipped the route middleware around it: a handler that failed lost its session changes and its `Set-Cookie`, so a `logout` followed by an error left the user logged in, and error responses had no `X-RateLimit-*` headers. It now becomes a response at the layer that threw it, as Laravel's pipeline does, and every outer middleware finishes. Metrics and Pulse record the real status instead of 500 for every exception. **A middleware that wraps `next` in a transaction now gets a response, not an exception, so it does not roll back on its own.**
- `insert()` with several rows dropped the columns the first row did not name, silently. A row with other columns than the first is now an `ArgumentError` before any SQL runs, also when it names fewer: Laravel's statement fails too.
- `Cast.integer` turned the string `168.6`, as PostgreSQL returns `numeric`, into `null`. It now reads strings as PHP's `(int)`: `168`, and `0` for text with no leading number.
- `WithoutOverlapping` kept its lock in the `process` store whatever `QUEUE_UNIQUE_LOCK_STORE` said, so workers in other processes ran the same job together. It now uses that setting.

## 1.21.0

The web session guard, and a round of fixes from running beside real Laravel
8 to 13 applications (`bench/interop/laravel_matrix.sh`).

**Three changes can affect a running application:** relation keys in
`Model.toJson` are now snake_case (`Model.snakeAttributes = false` keeps the old
keys); a middleware placed before `auth` on a route no longer sees bindings;
PostgreSQL date columns without a cast are text in JSON, not ISO-8601.

### Fixed

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
- `bench/interop/laravel_matrix.sh`: Daravel beside real Laravel 8 to 13 applications on one database (sessions both ways in both formats, encrypted or not; `Crypt` and bcrypt both ways; 422, 404 and 405 bodies byte for byte; `dartisan adopt`).

## 1.20.1

Three fixes found while adopting a Laravel 13 application. Sessions written
as JSON were overwritten, which logged users out of Laravel; `test:e2e --serve`
could run `migrate:fresh` on the database of a `DB_URL` in `.env`; and
`dartisan adopt` left an application on another version's formats.

### Fixed

- `daravel_session` treated a JSON session (`'serialization' => 'json'`, the laravel/laravel 13 skeleton) as empty and overwrote its row in PHP `serialize()` format, which logged the user out of the Laravel application sharing the store. Both formats are now read, also with `SESSION_ENCRYPT`, and a stored session is written back in the format it has.
- `dartisan e2e:install` overrode only `DB_DATABASE` for `test:e2e --serve`, so a `DB_URL` in the project's `.env` sent `migrate:fresh --seed` to the real database. `playwright.config.ts` now sets `DB_CONNECTION=sqlite` and `DB_URL=sqlite:<E2E_DATABASE>`. **Run `dartisan e2e:install --force` in existing projects, or make the same change by hand.** Projects whose migrations need PostgreSQL or MySQL test a running server with `--url`.
- The tests from `dartisan new` and `make:test` had the same gap with `DB_DATABASE=:memory:`; they now set `DB_CONNECTION=sqlite` and `DB_URL=sqlite::memory:`. Existing projects with a `DB_URL` should change their tests' `env:` the same way.
- `dartisan adopt` treats Laravel 8 to 13 as supported and writes `COMPAT_LARAVEL_VERSION` for the version it finds: an adopted Laravel 8 application answered with Laravel 12's error and validation formats. The old message still said the conformance suite pins Laravel 12.

### Added

- `SESSION_SERIALIZATION` (`php` or `json`): the format of new sessions, `php` by default and `json` with `COMPAT_LARAVEL_VERSION=13`. `dartisan adopt` copies it from the Laravel project's `config/session.php`, because a Laravel application upgraded to 13 keeps `php` unless it added the key.

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
