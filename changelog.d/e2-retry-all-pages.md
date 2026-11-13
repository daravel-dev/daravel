### Added

- `FailedJobPages` (`lastId`, `page`, `countBetween`), implemented by `DatabaseFailedJobProvider` and `MemoryFailedJobProvider`: failed jobs read a page at a time by id. `RetryAllResult`, `SkippedFailedJob` and `RetryAllRunningException`. `dartisan queue:retry --queue=name` retries every failed job of a queue, as Laravel's.

### Changed

- `QueueManager.retryAllFailed` (`queue:retry all`, Horizon's retry-all) reads the failed jobs a page at a time instead of all at once (measured: 100 000 failed jobs on SQLite in 100 calls with RSS at most 3 MiB higher, 20 000 on PostgreSQL and MySQL at most 5 and 6 MiB), never goes past the last failed job there was when the run began (a job failing again at once is not retried again by the same run), and holds the lock `queue:retry-all` in the queue's signal store while it runs: a second run at the same time throws `RetryAllRunningException` instead of pushing the same jobs twice. A job whose payload cannot be read stays in `failed_jobs` and is reported as skipped, and the others are still retried (Laravel pushes it as `null`). It takes `limit`, `budget`, `after`, `upTo` and `queue`, and returns a `RetryAllResult`. Horizon's `POST /horizon/api/jobs/retry-all` pushes at most 1 000 jobs or 10 seconds' worth per request and nothing after its answer, which is `{"retried": n, "skipped": [...], "skipped_count": n, "remaining": n, "after": id, "up_to": id}`; a retry-all already running answers 409, and the dashboard calls again until none remain. `dartisan queue:retry all` goes on past a skipped job and ends with 1 when it left one.

### Upgrade notes

- `QueueManager.retryAllFailed()` returns a `RetryAllResult` instead of the list of failed jobs (`result.retried` holds their uuids), and Horizon's retry-all answers a count with `remaining` instead of the list of uuids: code calling either reads the new shape. New public names `FailedJobPages`, `RetryAllResult`, `SkippedFailedJob` and `RetryAllRunningException` in `package:daravel` (an application class of one of these names and the barrel import give an ambiguous-import error; `hide` it or rename yours).
