### Added

- `Job.uniqueKeyHashesDisplayName` (ADR-041): a job whose Laravel class defines `displayName()` sets it, and its unique lock is `laravel_unique_job:<xxh128 of the display name>:<uniqueId>`, as `UniqueLock::getKey` builds it (12.x and 13.x), so both applications take the same lock. `QueueLockKeys.unique(displayName, uniqueId, hashed:)` builds that key; the conformance test checks it against the value PHP gives.

### Fixed

- A worker frees the unique lock of a job dispatched with a hashed key together with the previous release's key (it freed only the hashed one, leaving the other until `QueueLockKeys.legacyWindow`); a key of the previous release frees both current forms.
