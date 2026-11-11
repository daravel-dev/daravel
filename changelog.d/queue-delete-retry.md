### Added

- `DatabaseManager.isRetryable(error, connection:)`: whether a statement's error is one a retry may clear (a deadlock or serialization failure, SQLite busy or locked), what `transaction(attempts:)` retries, for a statement run alone.

### Fixed

- The database queue retries the delete (and the release) of a job a worker ran after a transient error, such as SQLite busy or locked or a MySQL deadlock, with jittered backoff, for as long as the reservation is safely the worker's (half of `retry_after`). Before, one such error after the job's handler had run left its row reserved, and the job ran a second time once `retry_after` passed, with no worker killed. An error a retry cannot clear is not retried, and past the bound the job may still run again: the queue's at-least-once guarantee, as in Laravel.
