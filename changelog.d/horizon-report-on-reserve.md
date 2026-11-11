### Added

- `WorkerOptions.onReserved`: called synchronously with each job the moment the driver reserved it, before it is decoded (`fromJson`), announced (`JobProcessing`) or run. An error it throws is logged and the job is processed all the same. `WorkerOptions.onFinished`: called once the worker is done with each such job, whatever happened (processed, failed, released, deleted, or failed before it ran), since not every way out has a lifecycle event.

### Changed

- `daravel_horizon`: a worker reports the job it runs the moment it reserved it (`onReserved`), not at `JobProcessing`: the same one message per job, sent before anything of the job can block the isolate. A worker blocked in a job's `fromJson` is now known to run that job: it is judged by the job's timeout (not killed for its lease) and its job reclaimed at once, instead of coming back after `QUEUE_RETRY_AFTER`. The report is cleared at `onFinished`, so a job that leaves with no lifecycle event (an unknown name, tries used up on its pop, released by middleware, a superseded debounce) leaves its worker idle. The job's limit counts from its reservation, as the driver's `retry_after` does. The heartbeat field `jobStartedAtMs` is now `jobReservedAtMs`; Horizon's dashboard does not show it.

### Upgrade notes

- `daravel_horizon`: `Heartbeat.jobStartedAtMs` is renamed `jobReservedAtMs` (the reservation time), for code reading the master's messages directly.
