### Added

- `QueuedJob.attemptsExhausted`: the driver cannot count another attempt (the database queue at 255); the worker fails such a job with `MaxAttemptsExceededException` without running it. `DatabaseQueue` takes `isKnownJob` (the application passes its job registry) and `logger`, and `DatabaseQueue.isForeignPayload` an optional `isKnownJob`.

### Fixed

- Database queue: a worker whose reservation ran out while its job ran (a handler that blocked its isolate past `retry_after`) no longer deletes or releases the job another worker has taken since. Its `delete` removed that worker's job, and its `release` let a third worker run it at the same time. `delete` now acts only while the row's `attempts` (raised by every reservation) are still the job's, and `release` only while the row is also still reserved, as `extend` already did; otherwise they do nothing and warn once per job ("ran past retry_after"). Stricter than Laravel, whose `deleteReserved` checks only that the row exists.
- Database queue: a registered Daravel job whose data holds a string `command` field was taken for a Laravel job and never popped. A job name registered in the application is now always Daravel's.
- Database queue: more than 1,000 foreign rows (jobs a Laravel app pushed onto the same queue) ahead of a Daravel job hid it: with 10,000 the job was not reached in 1,050 pops on SQLite, PostgreSQL and MySQL. `pop` now reads past foreign rows with a cursor per queue, in growing batches, and finds rows below it that become available later (a delayed job falling due, a release, a stale reservation) with a narrow query; with 100,000 foreign rows the job is reached in 19 pops.
- A job that fails for good is written to `failed_jobs` before it is removed from its queue, in one transaction when the database queue and `failed_jobs` are on the same connection. Before, a write that failed lost the job without a record. Laravel removes it first.
- Database queue: a job at 255 attempts (`TINYINT UNSIGNED` in Laravel's `jobs` table) failed every `pop` on MySQL with an out-of-range error and held every job behind it. It is now failed with `MaxAttemptsExceededException` without running, also with `tries: 0`, and an error claiming one row passes it over instead of stopping the queue.

### Upgrade notes

- Upgrading can change which rows the database queue takes and when a failed job is removed: a job name registered in the application is popped even when its data has a string `command` field; an unregistered Daravel-shaped job with such a field is skipped as foreign, as before; a stale worker's `delete`/`release` does nothing and logs a warning (the guard holds once every worker runs 1.28.0); a failed job is written to `failed_jobs` before it is removed; `tries: 0` ends at 255 attempts on the database queue. New public names: `QueuedJob.attemptsExhausted`, `DatabaseQueue.isKnownJob`, `DatabaseQueue.logger`, and the `isKnownJob` parameter of `DatabaseQueue.isForeignPayload`.
