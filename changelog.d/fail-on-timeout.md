### Added

- `TimeoutExceededException` (Laravel's `TimeoutExceededException::forJob`, "<name> has timed out."): the error of a job failed for running past its timeout, in `failed_jobs`, `JobFailed` and `failed()`. It implements `dart:async`'s `TimeoutException`. `JobProcessor.failsAfterTimeout(payload, attempts, tries:)` is the rule of Laravel's timeout handler (tries used up or `retryUntil` passed, then the last allowed exception of `maxExceptions`, then `failOnTimeout`); `JobProcessor.failReserved` fails a reserved job without running it; `WorkerOptions.failBeforeRun` lets a supervisor fail a job at its reservation. Guide: [Background work](docs/guide/background.md).

### Changed

- A job failed by its timeout records `TimeoutExceededException: <name> has timed out.` in `failed_jobs.exception` instead of `TimeoutException after 0:00:…: Future not completed`. Code catching `TimeoutException` still catches it.
- Only the worker's own timer is a job's timeout: a `TimeoutException` the handler throws itself (an HTTP client's, say) is an ordinary failure, retried with backoff. Before, it counted as the job's timeout, so a `failOnTimeout` job failed at once and any other job stopped the worker for a restart.
- A timeout counts towards `maxExceptions`, as in Laravel's timeout handler; before, only other exceptions did.
- `daravel_horizon`: a job whose worker the master killed past its timeout now fails by that same rule. The master decides from the payload the worker reported (`Heartbeat.jobPayload`) and marks the job in the queue's signal store (`HorizonSignals.markTimedOut`, at least `HorizonMaster.timedOutMarkTtl`); the worker that reserves it next fails it without running it, with `TimeoutExceededException`, its `failed()` hook and `JobFailed` running in that worker's application, never in the master. A job on its last try that times out therefore fails with `TimeoutExceededException` rather than `MaxAttemptsExceededException` on the pop after. `JobTimedOut` and `horizon:list` give each killed attempt's `fate` ("will fail on next reservation", "made available again", "left to retry_after"). Unlike Laravel, the failure is recorded at that next reservation, not at the moment of the timeout. Wired by `dartisan horizon` and `withHorizon()`; a `HorizonMaster` built in code without `signals` and `failsAfterTimeout` keeps the old behaviour.

### Upgrade notes

- New public name `TimeoutExceededException` in `package:daravel` (an application class of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours). A `failed_jobs` query or alert matching the old `TimeoutException` text of a timed-out job needs the new one.

### Fixed

- `daravel_horizon` ignored `failOnTimeout`, `maxExceptions` and the timeout of a job's last try when it killed a worker blocked past the job's timeout: a `failOnTimeout` job ran again, and a job out of tries failed only on its next pop, with another error.
