# ADR-003: State scopes (isolate, process, cluster)

> Reconstructed from code on 2026-10-27; maintainer to review. The original
> decision is in the maintainer's design documents (BLUEPRINT_V2), which
> are not public; this record is written from the code and its comments
> only.

## Context

A Daravel server can run several worker isolates on one port
([ADR-004](0004-supervisor-and-workers.md)). Isolates share no memory, so
state that Laravel keeps in one place (a rate-limit counter, a cache entry,
a lock) exists once per isolate unless something holds it for all of them.
Some state must also hold across processes and machines.

## Decision

Every piece of shared state declares where it lives, as a `StateScope`
(`server/coordinator.dart`):

| Scope | Meaning (from the code) | Examples |
| :-- | :-- | :-- |
| `isolate` | Fast, but every isolate has its own copy. | `MemoryStore` (cache), `MemoryRateLimitStore` |
| `process` | Consistent within one process: served by the coordinator isolate. | `ProcessStore` (cache and locks), `ProcessRateLimitStore`, merged metrics, broadcast fan-out |
| `cluster` | Shared across processes and servers (Redis, database). | `DatabaseStore` (Laravel's `cache` / `cache_locks` tables), `FileStore` on a shared disk, the Redis stores of `daravel_redis` |

`process` state is held by the `Coordinator`, which hosts services
(`CoordinatorService`) answering `op` + `args` messages:

- In one isolate, `LocalCoordinatorChannel` calls the coordinator directly,
  with no message hop.
- Under a supervisor, workers use `RemoteCoordinatorChannel`: a request
  over a `SendPort` with a correlation id and a timeout (1 s by default).
- The coordinator rejects requests above `maxQueue` (10 000 pending) with
  "Coordinator queue is full" (backpressure). Synchronous services (rate
  limits, the memory cache, locks) are answered inline, without a Future
  per message.

Failure policy differs by use:

- **Rate limiting fails open.** `ProcessRateLimitStore` allows the request
  when the coordinator errors or times out (50 ms by default) and notifies
  `onError`.
- **Locks fail closed.** `ProcessStore` lock calls propagate coordinator
  errors.

### Rate-limit leases

Asking the coordinator on every request costs a round trip per request and
does not scale with the number of isolates. `ProcessRateLimitStore`
therefore serves generous limits from local leases:

- Keys whose limit is at least `leaseThreshold` (32) take a batch of hits
  from the coordinator in one round trip and spend it in memory. Smaller
  limits, such as login limits, always go to the coordinator.
- The batch starts at 1, doubles (up to `maxLease`, 16) while leases are
  used up within `leaseTtl` (200 ms), and resets to 1 when they are not.
- Unused hits are released back to the coordinator (ignored once their
  window is over), so, as the code puts it, the limit is never exceeded nor
  under-delivered.
- A worker that saw a key blocked answers `429` locally for
  `blockedCacheTtl` (100 ms) instead of asking again.

The counters themselves follow Laravel's fixed-window model: a hit count
and the time the window resets, started by the first hit, O(1) per key.

These leases were added in commit `4169cf6` together with
[ADR-024](0024-laravel-coexistence-defaults.md); they are a performance
measure for the `process` scope, not part of ADR-024's decision.

## Consequences

- A limit such as `throttle:60,1` holds for the whole server, not per
  worker, by default.
- The coordinator runs on the supervisor's main isolate, which also
  respawns and drains workers. A slow asynchronous service there would
  delay both; `test/server/coordinator_services_test.dart` requires every
  standard service to answer synchronously (the process cache is the
  documented exception: in-memory work behind the asynchronous
  `CacheStore` interface).
- With several servers, `process` state is per server; state that must
  hold across servers needs a `cluster` store.
- `/metrics` exposes the coordinator's `coordinator_messages_total`,
  `coordinator_rejected_total` and `coordinator_in_flight`, so a flood of
  messages shows on a running server. (`dartisan coordinator:stats` shows
  only the coordinator of its own process.)

## Sources

- `packages/daravel/lib/src/server/coordinator.dart`
- `packages/daravel/lib/src/http/rate_limiter.dart`
  (`MemoryRateLimitStore`, `RateLimitService`, `ProcessRateLimitStore`)
- `packages/daravel/lib/src/cache/stores.dart`
  (`MemoryStore`, `ProcessCacheService`, `ProcessStore`, `FileStore`,
  `DatabaseStore`)
- `CHANGELOG.md`, "Performance" under 1.0.0-beta.1
