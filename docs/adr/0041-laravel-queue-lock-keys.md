# ADR-041: Laravel's cache keys for unique, overlap and debounce locks

- **Status:** accepted by the Tech Lead (ACK 245, ACK 254 §2.4–2.8), 2026-11-11; part of the 1.28.0 gate (G1.5).
- **Context:** Daravel and Laravel are meant to run side by side on the same database and cache. A queued job's unique lock, `WithoutOverlapping` lock and debounce owner are cache entries. Daravel named them its own way, so a Laravel and a Daravel application sharing a cache did not see each other's locks: the same unique job could be pending on both sides.

## Decision

The keys follow Laravel. The cache prefix is the store's own (`CACHE_PREFIX` must be the same in both applications, as for any shared cache entry).

| Lock | Laravel (source) | Daravel before | Daravel now |
| :-- | :-- | :-- | :-- |
| unique | `'laravel_unique_job:'.$jobName.':'.$uniqueId` with `$jobName = get_class($job)`, or `hash('xxh128', $job->displayName())` when the job defines `displayName()` (`src/Illuminate/Bus/UniqueLock.php`, 12.x, lines 66–77; identical in 13.x) | `unique:<jobName>:<uniqueId>` | `laravel_unique_job:<displayName>:<uniqueId>` |
| overlap | `$this->prefix.$jobName.':'.$this->key`, prefix `laravel-queue-overlap:`; `prefix.key` when `shared()` (`src/Illuminate/Queue/Middleware/WithoutOverlapping.php`, 12.x, lines 41 and 157–168) | `overlap:<jobName>:<key>` / `overlap:<key>` | `laravel-queue-overlap:<displayName>:<key>` / `laravel-queue-overlap:<key>` |
| debounce | `'laravel_debounced_job:'.$jobName.':'.$debounceId` (`src/Illuminate/Bus/DebounceLock.php`, **13.x**, lines 159–170; 12.x has no `DebounceLock`) | `debounced_job:<jobName>:<debounceId>` | `laravel_debounced_job:<displayName>:<debounceId>` |

- **`<displayName>`:** the job's `displayName`, which is the payload's `displayName` that the queue format already shares with Laravel: the class name on the Laravel side. A Laravel job class without a `displayName()` method (the usual case: neither `Queueable` trait defines one) uses its class name unhashed, so the keys match when the Daravel job's `displayName` is that class name, as queue interop already requires.
- **Not followed yet:** the `xxh128(displayName())` branch, for a Laravel job class that defines `displayName()`. It needs XXH3-128 in pure Dart, which is a separate change (G1.5 d): a per-job option then hashes the name.
- **`uniqueFor` 0:**
  - Laravel locks forever.
  - Daravel keeps 365 days, so a lock left behind by a crash recovers. This is a deliberate difference.
- **A savepoint released and then rolled back with its parent** gives its unique lock back. Laravel's `DatabaseTransactionsManager::removeCommittedTransactionsThatAreChildrenOf` runs no rollback callbacks there and keeps the lock until `uniqueFor`. This is a deliberate difference (G1.5 a/b).

## Transition (rolling deploy)

During a deploy, instances of the previous release know only the old keys. Checking the old key from the new release would protect one direction only, so both keys are taken:

- **Unique and overlap:** a dispatch (or a job run, for overlap) takes the old key, then the new one. If the second fails, the first is released and the dispatch is refused (or the job released). Release gives both back. A worker derives both keys from the payload's `uniqueKey`, `displayName` and `jobName`, so it releases a lock taken by either release.
- **Debounce:**
  - the owner is written under both keys, and a rollback restores both;
  - a worker reads Laravel's key and falls back to the old one;
  - `first_dispatched_at` (`debounceMaxWait`) lives under Laravel's key only.
  - **Limit:** while both releases dispatch the same debounce id in the same burst, an instance of the previous release reads only the old key, so one extra run (or one dropped duplicate) of that burst is possible during the deploy window.
- **Removal:** the transition is one constant, `QueueLockKeys.legacyKeys`. It is removed in the minor release after 1.28.0, which then takes and writes Laravel's keys only.

## Consequences

- **Locks taken before the upgrade:** after the upgrade, a unique lock taken by the previous release under `unique:…` still blocks a new dispatch, because the old key is taken first. A lock taken by the new release is visible to Laravel.
- **Code that read these cache keys itself** (`unique:…`, `overlap:…`, `debounced_job:…`) must use `QueueLockKeys`.
- **Locked by tests:** the conformance test `packages/daravel/test/conformance/queue_lock_keys_conformance_test.dart` holds the formats against `LaravelContract`.
