### Added

- `JobProcessing.timeout`: how long the handler may run, the value the processor enforces (the worker's `--timeout` when given, otherwise the job's own `timeout`), so a supervisor kills a worker whose handler blocks at the same point.

### Fixed

- `daravel_horizon` (Blueprint #134): a job doing synchronous work that blocks its isolate for longer than four heartbeats (about 4 s by default) is no longer killed for its lease on every attempt and then quarantined without ever finishing. The master now judges a worker that runs a job by that job's timeout (the plan's `timeout`, otherwise the job's own) plus `HORIZON_KILL_GRACE`, at the latest one heartbeat (at least 1 s) before `QUEUE_RETRY_AFTER` (a job killed that close is left to `retry_after`, not reclaimed, so the master never releases a reservation another worker may hold already), also from its own timer, so a silent worker is judged too; only an idle worker that stops answering is killed for its lease. A worker killed past its job's timeout is not a crash: the attempt counts once, the job is available again at once, and a job with no tries left fails on its next pop with `MaxAttemptsExceededException` (with `JobFailed`), not quarantined. The master logs each such kill with the job's uuid, name and attempt, and `horizon:list` shows a busy worker that does not report as "not reporting for N s" and lists the attempts killed past their timeout (`horizon:status` counts them). `HorizonConfig.check` warns when a plan's `timeout` plus `killGrace` exceeds `QUEUE_RETRY_AFTER`. Known limits, in the guide: a killed attempt dispatches no `JobExceptionOccurred`, `failOnTimeout` does not apply to it, and a worker blocked in a job's `fromJson` (before the job is reported) has its job back only after `QUEUE_RETRY_AFTER`.

### Upgrade notes

- `daravel_horizon`: new public name `horizonWorkerLines` in `package:daravel_horizon/commands.dart` (what `horizon:list` prints). `HorizonMaster.status()` gains `silentMs` on busy workers and a `timedOut` list; the `Heartbeat` message gains `jobTimeoutMs`, `jobName` and `attempt`.
