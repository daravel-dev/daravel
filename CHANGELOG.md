# Changelog

All notable changes to the Daravel workspace (`daravel`, `daravel_test`,
`daravel_lints`, `dartisan_cli`). Versions follow SemVer; until 1.0.0 the
beta releases may still change Laravel-facing formats when the conformance
suite shows they differ from Laravel.

## 1.0.0-beta.1 (Tier 1 / S14)

### Added

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
