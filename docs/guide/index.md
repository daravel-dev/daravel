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

## Guides

1. [Getting started](getting-started.md): install, create a project, serve, build.
2. [Routing](routing.md): routes, groups, middleware, resources, rate limits.
3. [Validation](validation.md): rules, form requests, the 422 format.
4. [Database](database.md): migrations, the query builder, models, pagination.
5. [Responses and resources](responses.md): JSON, API resources, errors.
6. [Authentication and authorization](auth.md): tokens, JWT, hashing, Crypt, gates.
7. [Cache, events, queues, scheduling](background.md).
8. [Strings, helpers and collections](helpers.md): `Str`, `retry`, `once`, `pluck`, ...
9. [Testing](testing.md): `TestClient`, database helpers, fakes, conformance.
10. [Deployment](deployment.md): native bundles, Docker, isolates, production checks.
11. [Laravel coexistence](laravel-coexistence.md): the compatibility contract.
12. [Security](security.md): secure defaults and the security suite.
13. [Performance](performance.md): the benchmark harness.
14. [Laravel ⇄ Daravel parity table](parity.md) (generated).

Bahasa Indonesia: [Dokumentasi Daravel](id/index.md).

Code samples in these guides are copied from compiled, tested files
(`packages/daravel/test/docs/guide_examples_test.dart`) by
`dart run tool/docs/generate.dart`, so they cannot go stale.
