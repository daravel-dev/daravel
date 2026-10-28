# Releases and versioning

Daravel `1.x` is the stable release line. The twelve packages (`daravel`,
`dartisan_cli`, `daravel_test`, `daravel_lints`, `daravel_mysql`,
`daravel_sqlite`, `daravel_postgres`, and since 1.12.0 `daravel_redis`,
`daravel_permission` and `daravel_teorion`, and since 1.13.0
`daravel_livekit` and `daravel_google`) are released together under one
version,
published on [pub.dev](https://pub.dev/packages/daravel) by the verified
publisher `framework.daravel.dev`.

| Version | Highlights |
| :-- | :-- |
| `1.15.0` | Excel and CSV (daravel_excel), a log viewer (daravel_log_viewer), `dartisan pub:add` to install packages, and a fix for commands that never exited with `withPermissions()` |
| `1.14.0` | Activity log (daravel_activitylog) and S3 storage (daravel_s3), HTTP limits (body, idle, WebSocket frames), database timeouts, and broad hardening across queue, scheduler, storage and packages |
| `1.13.0` | LiveKit (daravel_livekit) and Google (daravel_google), load shedding (HTTP_MAX_IN_FLIGHT, HTTP_MAX_QUEUE_DELAY), doctor notes, an operations guide, worker-labelled metrics, presence events across servers fixed |
| `1.12.0` | Redis and Valkey (daravel_redis), roles and permissions (daravel_permission), query filters (daravel_teorion), cache tags, eager loading specific columns, typed unique violations and createOrFirst |
| `1.11.0` | Broadcasting across servers (REVERB_SCALING_ENABLED), cache and encrypted channels, 10k connections, one-statement rate limits, wakeable queue workers |
| `1.10.1` | Security fixes: JWT revocation on every isolate, queue:restart and queue:pause across processes, unique-job locks |
| `1.10.0` | Broadcasting with Laravel Echo (the Pusher protocol, as Reverb; `ShouldBroadcast`, `BROADCAST_CONNECTION`), bcrypt in C on Linux |
| `1.9.0` | Mail and notifications (queued, markdown theme, broadcast channel), `Broadcast` across isolates, `DB_URL`, `dartisan upgrade`, Indonesian guide, benchmark against Laravel |
| `1.8.1` | Fix: `client:flutter --state` adapters without paginators or uploads pass `dart analyze --fatal-infos` |
| `1.8.0` | Driver packages, `db:install`, `db:transfer`, `withDatabaseConnection`; `client:flutter --state`/`--watch`; per-connection transactions |
| `1.7.0` | `dartisan client:flutter`: typed Dart/Flutter client with the server's validation rules on the device |
| `1.6.0` | Server-sent events (`Response.sse`, Laravel `eventStream` frames) and WebSocket routes (`router.ws`) |
| `1.5.1` | Fix: JSON numbers outside the double range (`1e309`) are a 400 instead of a 500 or a stored Infinity |
| `1.5.0` | `daragic:export` (DAM), `TestTransport.socket`, `TouchableCacheStore.touch`; fix for shared rate limits under concurrency |
| `1.4.1` | Fix: security headers no longer pile up across requests on a running server |
| `1.4.0` | Live `/docs/api` reference, localization (`trans`, `transChoice`, 280 locales' plural rules), `cache.headers` and gzip, Pennant-compatible feature flags, `db:backup`; fix for `HEAD` responses |
| `1.3.0` | Model registry and `model:show`, `mcp:serve` `models`/`db_query`/`read_logs`/`last_error`, `mcp:install`, `SCHEDULE_TIMEZONE`, lint `invalid_timezone`, SQLite-free Docker images; fix for `timezone('UTC')` |
| `1.2.0` | DI bindings and `inject()`, fluent string/date/number helpers, Carbon calendar math, date query shortcuts, `DB.whenQueryingForLongerThan`, `Context`, typed HTML builder, IANA scheduler zones, `build --no-sqlite`, `mcp:serve` |
| `1.1.0` | Polymorphic relations, nested `whereHas`, relation aggregates, synchronous query input, chained rules, two new lints, near cache and shared rate limits; fixes for concurrent transactions, database cache counters and PostgreSQL subqueries |
| `1.0.0` | First stable release: file uploads, MySQL and MariaDB (`daravel_mysql`), `Http` client, maintenance mode, `db:show`/`db:table`/`tinker` |
| `1.0.0-beta.3` | Route metadata (`.validates()`, `.returns()`) and OpenAPI schemas, typed request input, `.env.encrypted`, `dartisan adopt`, embedded queue and scheduler, faster request path |
| `1.0.0-beta.2` | `dartisan` delegation, welcome page, Laravel queue guard, `PORT` fallback |
| `1.0.0-beta.1` | First public release: the complete Tier 1 framework |

The full notes are in the
[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md)
and on the [GitHub releases](https://github.com/daravel-dev/daravel/releases)
page.

## Versioning

- The Dart API follows SemVer: `1.x` releases add features and fix bugs
  without breaking existing code; breaking changes wait for `2.0`.
- The Laravel-facing formats (error and pagination JSON, Sanctum tokens,
  bcrypt hashes, `Crypt` payloads, shared tables) are locked by the
  conformance suite. They change only to match Laravel more closely, and the
  changelog says so.
- Security fixes are released for the `1.x` line; the `1.0.0` betas are no
  longer supported.

## Branches

Like Laravel, Daravel keeps one branch per major version. `main` is where
development happens; `1.x` follows the latest `1.x` release. These docs exist
for both: `1.x` is the default, `main` describes unreleased work.
