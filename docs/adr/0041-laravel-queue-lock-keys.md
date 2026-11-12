# ADR-041: Laravel's cache keys for unique, overlap and debounce locks

- **Status:** accepted 2026-11-11; part of the 1.28.0 gate (G1.5).
- **Context:** Daravel and Laravel are meant to run side by side on the same database and cache. A queued job's unique lock, `WithoutOverlapping` lock and debounce owner are cache entries. Daravel named them its own way, so a Laravel and a Daravel application sharing a cache did not see each other's locks: the same unique job could be pending on both sides.

## Decision

The keys follow Laravel. The cache prefix is the store's own (`CACHE_PREFIX` must be the same in both applications, as for any shared cache entry).

| Lock | Laravel (source) | Daravel before | Daravel now |
| :-- | :-- | :-- | :-- |
| unique | `'laravel_unique_job:'.$jobName.':'.$uniqueId` with `$jobName = get_class($job)`, or `hash('xxh128', $job->displayName())` when the job defines `displayName()` (`src/Illuminate/Bus/UniqueLock.php`, 12.x, lines 66–77; identical in 13.x) | `unique:<jobName>:<uniqueId>` | `laravel_unique_job:<displayName>:<uniqueId>` |
| overlap | `$this->prefix.$jobName.':'.$this->key`, prefix `laravel-queue-overlap:`; `prefix.key` when `shared()` (`src/Illuminate/Queue/Middleware/WithoutOverlapping.php`, 12.x, lines 41 and 157–168) | `overlap:<jobName>:<key>` / `overlap:<key>` | `laravel-queue-overlap:<displayName>:<key>` / `laravel-queue-overlap:<key>` |
| debounce | `'laravel_debounced_job:'.$jobName.':'.$debounceId` (`src/Illuminate/Bus/DebounceLock.php`, **13.x**, lines 159–170; 12.x has no `DebounceLock`) | `debounced_job:<jobName>:<debounceId>` | `laravel_debounced_job:<displayName>:<debounceId>` |

- **`<displayName>`:** the job's `displayName`, which is the payload's `displayName` that the queue format already shares with Laravel: the class name on the Laravel side. A Laravel job class without a `displayName()` method (the usual case: neither `Queueable` trait defines one) uses its class name unhashed, so the keys match when the Daravel job's `displayName` is that class name, as queue interop already requires.
- **The `xxh128(displayName())` branch**, for a Laravel job class that defines `displayName()`: a job opts in with `Job.uniqueKeyHashesDisplayName`, and its unique lock is named by `Xxh128.hex(displayName)` (XXH3-128, ported from `xxhash.h` v0.8.2). It is opt-in, not inferred, because Dart cannot tell whether the Laravel class defines `displayName()`. The conformance test checks the key against the value PHP 8.2's `hash('xxh128', …)` gives. A worker frees the hashed key with the previous release's; a key of the previous release frees both current forms, since that release could not know which one this release takes.
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
- **Window on the old keys** (`QueueLockKeys.legacyWindow`, 1 hour; the old keys this release takes or writes live `min(ttl, legacyWindow)`):
  - **The gap it closes:** a unique job dispatched by this release but finished by a worker of the previous release. That worker releases only the payload's `uniqueKey` (Laravel's key), so the old key it does not know is left behind. Without the bound it would refuse the id for the job's `uniqueFor` (365 days for 0), and the next dispatch would be dropped with only a debug log line.
  - **What remains:** for up to one hour after the last worker of the previous release stopped, such an id can still be refused.
  - **The other side of the bound:** a duplicate is possible only if an instance of the previous release still dispatches the same unique id more than one hour after this release created it.
  - **The other direction:** dispatched by the previous release and run by this release, both keys are released (`uniqueKeysOf`).
  - **Debounce:** the old key holds the same owner as Laravel's (written together), so a worker of the previous release reading only the old key keeps the burst's last dispatch. Past the window the old key is gone, and such a worker runs the job (no owner means run, by design), so at most one extra run is possible.
  - **`WithoutOverlapping`:** its two locks are taken and released by the same worker around the job, so nothing is left behind when a worker of the other release runs the next job. A worker killed mid-job leaves them until `expiresAfter`, as Laravel does.
- **Removal:** the transition is one constant, `QueueLockKeys.legacyKeys`. It is removed in the minor release after 1.28.0, which then takes and writes Laravel's keys only.

## Consequences

- **Locks taken before the upgrade:** after the upgrade, a unique lock taken by the previous release under `unique:…` still blocks a new dispatch, because the old key is taken first. A lock taken by the new release is visible to Laravel.
- **Code that read these cache keys itself** (`unique:…`, `overlap:…`, `debounced_job:…`) must use `QueueLockKeys`.
- **Locked by tests:** the conformance test `packages/daravel/test/conformance/queue_lock_keys_conformance_test.dart` holds the formats against `LaravelContract`.
