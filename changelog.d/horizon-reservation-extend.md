### Added

- `ExtendingQueueDriver`: a queue that reserves and says how far it extended a running job's reservation (`extend`, the new end with the guarantee of `QueuedJob.reservedUntil`, or `null` when nothing changed). The database and Redis queues implement it; `touch` stays as it is.
- `WorkerOptions.extendEvery` (how often a running job's reservation is extended; half `retry_after` by default, above zero) and `WorkerOptions.onReservationExtended` (told each new end).

### Fixed

- The worker extended a running job's reservation from a periodic timer without waiting for the previous extension: on a slow database the writes piled up. A tick while one is still on its way is now skipped.
- Horizon: a job that kept running (awaiting) past `retry_after` was killed by the end of its first reservation, although its worker kept extending it. Workers now tell the master each extension and the master moves its limit along; under Horizon they extend every half of what the master leaves a job (0.5 s for a `QUEUE_RETRY_AFTER` of 3 s on the database queue, two writes a second per running job). An extension the master does not hear of in time makes it kill early, never run the job twice.

### Upgrade notes

- A queue driver of your own that reserves can implement `ExtendingQueueDriver` so Horizon follows its extensions; without it, its jobs are still killed by the end of their first reservation.
