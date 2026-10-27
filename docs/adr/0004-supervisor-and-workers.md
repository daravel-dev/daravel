# ADR-004: Supervisor, worker isolates and coordinator

> Reconstructed from code on 2026-10-27; maintainer to review. The original
> decision is in the maintainer's design documents (BLUEPRINT_V2), which
> are not public; this record is written from the code and its comments
> only.

## Context

A Dart isolate runs one event loop on one core. A server in one isolate
leaves the other cores of the machine idle, and CPU-bound work in a handler
(hashing, JSON, synchronous SQLite) delays every other request on it.
Isolates share no memory, so state that must be consistent across them
needs an owner ([ADR-003](0003-state-scopes.md)).

## Decision

`Application.serveWith(createApp)` serves in-process when `isolates <= 1`.
Otherwise a `Supervisor` in the main isolate (`server/supervisor.dart`):

1. **Spawns N HTTP workers** (`Isolate.spawn`, named `daravel-worker-N`).
   Each worker calls the application factory, which must be a top-level
   function (or a closure capturing nothing) so it can be sent to the
   isolate, and binds the same port with `shared: true`.
2. **Hosts the coordinator** for `process`-scope state. The standard one
   (`createStandardCoordinator`) serves rate limiting, the process cache,
   merged metrics, broadcast fan-out and channel membership.
3. **Waits for readiness**: each worker reports `WorkerReady` (or
   `WorkerFailed`) once bound; a worker not ready within `readyTimeout`
   (30 s by default) fails the start.
4. **Respawns crashed workers** with a backoff of 1, 2, 4 … up to 32
   seconds. More than `maxCrashesPerMinute` (5) crashes within a minute is
   a crash loop: the supervisor exits with code 1.
5. **Drains on signals**: it sends `drain` to every worker, waits for
   `WorkerDrained` up to `SHUTDOWN_TIMEOUT` plus two seconds, then kills
   the workers that are left.

Work that would block a worker's event loop runs elsewhere: password
hashing runs in a compute isolate (`Isolate.run`), so a 100 ms Argon2id
derivation does not stall other requests (`auth/hashing.dart` cites
ADR-004 for this).

## Consequences

- One port, every core. `APP_ISOLATES` (or `serve --isolates`) sets N.
- The operating system distributes *connections* over the workers, not
  requests: a client (or proxy) holding one keep-alive connection stays on
  one worker. `http_requests_in_flight{worker}` shows uneven workers.
- Anything shared must go through the coordinator or a `cluster` store; an
  in-memory SQLite database cannot be shared, so `serve` refuses `:memory:`
  with more than one isolate, and a SQLite file under several isolates
  logs a warning (its synchronous calls block a worker's event loop while
  it waits for another isolate's lock).
- Each worker has its own database pool: a deployment opens up to
  `instances × APP_ISOLATES × DB_POOL_SIZE` connections.
- The coordinator shares the main isolate with respawn and drain, so its
  services must answer synchronously (see ADR-003).
- Metrics are merged across workers by the coordinator; the process's
  resident memory is reported once.

## Sources

- `packages/daravel/lib/src/server/supervisor.dart`
- `packages/daravel/lib/src/foundation/application.dart` (`serveWith`)
- `packages/daravel/lib/src/http/server_engine.dart`
- `packages/daravel/lib/src/auth/hashing.dart`
- `packages/daravel/lib/src/observability/metrics.dart` (`AppMetrics.render`)
