# Daravel documentation

Daravel is a backend framework for Dart that follows the Laravel 11/12
philosophy and compiles to a native AOT executable. If you know Laravel, you
already know where things are: routes, controllers, form requests, Eloquent
style models, migrations, queues, the scheduler and `artisan` (here
`dartisan`).

Laravel and Daravel are designed to run **side by side on the same
database**. Error and pagination JSON, Sanctum tokens, bcrypt hashes, `Crypt`
payloads and the framework tables use Laravel's formats, and a conformance
suite keeps them that way. See [Laravel coexistence](laravel-coexistence.md).

## Why Daravel?

1. **One native bundle**: AOT machine code with SQLite bundled; no runtime
   or source on the server ([Deployment](deployment.md)).
2. **No reflection, no `build_runner`**: generators write plain Dart into
   explicit registries.
3. **Every core on one port**: a supervisor with worker isolates and a
   coordinator for locks, cache and rate limits, without Redis.
4. **Request state stays in its request**: `Zone` scopes for requests, jobs
   and commands; zone-aware transactions.
5. **Runs next to Laravel** on the same database
   ([coexistence](laravel-coexistence.md),
   [migrating](migrating-from-laravel.md)).
6. **Routes that document themselves**: `.validates()` and `.returns()`
   enforce 403/422 and generate OpenAPI 3.1 ([Routing](routing.md)).
7. **Guard rails included**: hashing in compute isolates, AST lints, and
   [security](security.md) and conformance suites.

Performance numbers come from a reproducible harness, never from claims
([Performance](performance.md)).

## Guides

1. [Getting started](getting-started.md): install, create a project, serve, build.
2. [Routing](routing.md): routes, groups, middleware, resources, rate limits.
3. [Validation](validation.md): rules, form requests, the 422 format.
4. [Database](database.md): migrations, the query builder, models, pagination.
5. [Responses and resources](responses.md): JSON, API resources, errors.
6. [Authentication and authorization](auth.md): tokens, JWT, hashing, Crypt, gates.
7. [Cache, events, queues, scheduling](background.md).
8. [Strings, helpers and collections](helpers.md): `Str`, `retry`, `once`, `pluck`, ...
9. [HTTP client](http-client.md): outgoing requests with `Http`, retries and `Http.fake()`.
10. [Testing](testing.md): `TestClient`, database helpers, fakes, conformance.
11. [Deployment](deployment.md): native bundles, Docker, Cloud Run, VPS (systemd + Caddy).
12. [Laravel coexistence](laravel-coexistence.md): the compatibility contract.
13. [Migrating from Laravel](migrating-from-laravel.md): move endpoints one at a time behind a proxy.
14. [Security](security.md): secure defaults and the security suite.
15. [Performance](performance.md): the benchmark harness.
16. [Laravel ⇄ Daravel parity table](parity.md) (generated).

Bahasa Indonesia: [Dokumentasi Daravel](id/index.md).

Code samples in these guides are copied from compiled, tested files
(`packages/daravel/test/docs/guide_examples_test.dart`) by
`dart run tool/docs/generate.dart`, so they cannot go stale.
