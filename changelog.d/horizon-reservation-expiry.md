### Added

- `QueuedJob.reservedUntil`: for a queue that reserves, the moment before which the driver never hands the job to another worker, on the clock of the process that pops next. The database queue counts whole seconds (`reserved_at`), so a job popped at second *r* with `retry_after` *R* is kept until exactly second *r + R*: 2 to 3 s after the pop for a `retry_after` of 3 s, and a `retry_after` of 2.5 s counts as 2. The Redis queue keeps it until the pop plus `retry_after` to the millisecond (the stream engine on the Redis server's clock). `null` from a driver that does not say.

### Fixed

- Horizon: a job blocked in its worker could run a second time beside itself. The master killed it 1 s before `retry_after`, counted in milliseconds from the reservation, while the database queue hands a job out again up to a second before `retry_after` (it stores whole seconds), and the master noticed a blocked worker only on its periodic check, up to a heartbeat later. It now kills a heartbeat (at least a second) before the moment the driver states, with a timer per job. Boot refuses a `QUEUE_RETRY_AFTER` that would leave a job less than a second. Master and workers must use the same `QUEUE_RETRY_AFTER`; when they do not, the master kills by the earlier and warns once per supervisor. Not covered: a worker in another process or host whose clock runs ahead (the margin covers it while the difference stays below it), a process suspended past a reservation, a job that extends its reservation (`touch`), and the Redis stream engine on a server clock that runs fast or jumps ahead.

### Upgrade notes

- A queue driver of your own that implements `ReservingQueueDriver` keeps working; give its `QueuedJob`s a `reservedUntil` so Horizon kills exactly before it (without one, Horizon assumes whole seconds and may kill up to a second early).
