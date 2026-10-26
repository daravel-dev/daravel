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

The official packages are `daravel`, `dartisan_cli`, `daravel_test`,
`daravel_lints` and `daravel_mysql`, released together by the verified
publisher [`daravel.teoprayoga.my.id`](https://pub.dev/publishers/daravel.teoprayoga.my.id)
on pub.dev; only packages from that publisher belong to this project.
Daravel runs on Linux, macOS and Windows servers (pub.dev also lists Flutter,
since the packages are plain Dart).

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
8. [Mail and notifications](mail.md): SMTP, mailables, and mail and database notifications.
9. [Strings, helpers and collections](helpers.md): `Str`, `retry`, `once`, `pluck`, ...
10. [HTTP client](http-client.md): outgoing requests with `Http`, retries and `Http.fake()`.
11. [Flutter client](flutter-client.md): a typed client generated from the routes, with on-device validation.
12. [Testing](testing.md): `TestClient`, database helpers, fakes, conformance.
13. [Deployment](deployment.md): native bundles, Docker, Cloud Run, VPS (systemd + Caddy).
14. [Laravel coexistence](laravel-coexistence.md): the compatibility contract.
15. [Migrating from Laravel](migrating-from-laravel.md): move endpoints one at a time behind a proxy.
16. [Security](security.md): secure defaults and the security suite.
17. [Performance](performance.md): the benchmark harness.
18. [Laravel ⇄ Daravel parity table](parity.md) (generated).

Bahasa Indonesia: [Dokumentasi Daravel](id/index.md).

Code samples in these guides are copied from compiled, tested files
(`packages/daravel/test/docs/guide_examples_test.dart`) by
`dart run tool/docs/generate.dart`, so they cannot go stale.
