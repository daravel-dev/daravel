# Architecture

Daravel keeps Laravel's concepts and changes the mechanisms that an
ahead-of-time compiled, statically typed language cannot share with PHP.

## Request lifecycle

1. `bin/server` builds the application from `createApp()` in
   `bootstrap/app.dart` and boots it: environment, typed configuration and
   its validation, container bindings, service providers, routes.
2. Each request runs in its own scope (below), through the global
   middleware, the radix-tree router, route model binding, the route's
   middleware, declared validation (`.validates()`), and the handler.
3. The handler's result becomes a response: a `Response`, a resource, a
   model, a map or list (JSON), a string (text) or `null` (204).
4. After the response is written, terminable middleware and
   `request.defer()` callbacks run.

`404`, `405` (with `Allow`), `HEAD` and `OPTIONS` behave as in Laravel, and
exceptions render Laravel's JSON error bodies.

## Service container

`Container` binds services as singletons, scoped (one per request, job or
command) or transient factories. Service providers have Laravel's two
phases:

```dart
final class BillingServiceProvider extends ServiceProvider {
  const BillingServiceProvider();

  @override
  void register(Container container) {
    container.singleton<PaymentGateway>((c) => StripeGateway(c.make<Env>()));
  }

  @override
  Future<void> boot(Container container) async {
    // Every provider has registered; resolving is safe here.
  }
}
```

`DeferredServiceProvider` registers its bindings the first time one of its
types is resolved.

## Zones instead of global state

A PHP request starts from an empty process; a Dart server handles many
requests in one process at once. Daravel gives every request, queued job and
console command its own scope stored in a Dart `Zone`
(`Container.runScoped`). Facades such as `Auth`, `DB`, `Cache` and `Log`
resolve from the current zone first, so the authenticated user, the request
id in log lines or the active transaction belong to the request that is
running, even while others are suspended at an `await`.

Transactions use the same mechanism: `DB.transaction` puts its executor in
the zone, nested calls become savepoints, and queued jobs or
`dispatchAfterCommit` events wait for the outer commit.

## No reflection, explicit registries

AOT binaries have no `dart:mirrors`, and the compiler drops code that
nothing imports. What Laravel discovers by scanning folders is an explicit
list in `bootstrap/`: `migrations.dart`, `seeders.dart`, `jobs.dart`,
`policies.dart`, `listeners.dart` and `commands.dart`. `dartisan make:*`
maintains them, and `dartisan lint` reports files left out of a registry.

## Concurrency

With `APP_ISOLATES=N` (or `serve --isolates=N`), a supervisor starts N
worker isolates that share one port. It waits for every worker to be ready,
respawns a worker that crashes (and exits on a crash loop), and on `SIGTERM`
lets in-flight requests finish within `SHUTDOWN_TIMEOUT`.

Isolates share no memory, so state that must be process-wide lives in a
coordinator isolate: rate limits (`throttle:60,1` means 60 per minute for
the whole server, not per worker), the `process` cache store, atomic locks
and merged metrics. Every store declares its scope (`isolate`, `process` or
`cluster`); rate limiting fails open, locks fail closed.

## Time

Domain time (timestamps, token and cache expiry, schedules, signed URLs)
reads `Clock.now()`, so tests can freeze or move it with `freezeTime()` and
`travel()`.
