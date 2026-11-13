### Fixed

- `dartisan queue:retry all` with a failed job provider that does not read in pages (`FailedJobPages`; a third party's) reads it once, in one pass without a budget, as before 1.28.0: each 30-second pass read it all again, and on `sync` a job failing again at once could keep the passes going. The passes are `QueueRetryCommand.retryAll` (returning `RetryAllTotals`). `queue:retry all --queue=name` retries that queue only (Laravel's `all` takes every queue), now written in its help and in parity.
