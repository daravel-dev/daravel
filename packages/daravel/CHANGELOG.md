# Changelog

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
