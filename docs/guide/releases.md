# Releases and versioning

Daravel `1.x` is the stable release line. The five packages (`daravel`,
`dartisan_cli`, `daravel_test`, `daravel_lints`, `daravel_mysql`) are released
together under one version,
published on [pub.dev](https://pub.dev/packages/daravel) by the verified
publisher `daravel.teoprayoga.my.id`.

| Version | Highlights |
| :-- | :-- |
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
