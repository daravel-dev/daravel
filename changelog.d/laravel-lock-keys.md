### Added

- `QueueLockKeys`: the cache keys of a job's unique lock, `WithoutOverlapping` lock and debounce owner (ADR-041, `docs/adr/0041-laravel-queue-lock-keys.md`).

### Changed

- A queued job's unique lock, `WithoutOverlapping` lock and debounce owner use Laravel's cache keys (ADR-041): `laravel_unique_job:<displayName>:<uniqueId>` (`UniqueLock::getKey`), `laravel-queue-overlap:[<displayName>:]<key>` (`WithoutOverlapping::getLockKey`) and `laravel_debounced_job:<displayName>:<debounceId>` (Laravel 13's `DebounceLock::getKey`), so a Laravel and a Daravel application sharing a cache (same `CACHE_PREFIX`) and naming a job alike (its Daravel `displayName` = its Laravel class) see each other's locks; before, the same unique job could be pending on both sides. Laravel's `xxh128(displayName())` branch, for a job class that defines `displayName()`, is not followed yet.

### Upgrade notes

- During the rolling deploy of this release, both key formats are taken (the previous `unique:<jobName>:<id>`, `overlap:[<jobName>:]<key>` and `debounced_job:<jobName>:<id>` first, then Laravel's) and released, so instances of the previous and of this release refuse each other's duplicate dispatches; a worker releases both from the payload. While both releases dispatch the same debounce id in one burst, one extra or one dropped run of that burst is possible. The old keys stop being taken and written in the minor release after 1.28.0 (`QueueLockKeys.legacyKeys`). Code that read these cache keys itself must use `QueueLockKeys`. New public name `QueueLockKeys` in `package:daravel` (`hide` it or rename an application class of that name).
