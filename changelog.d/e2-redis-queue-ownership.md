### Fixed

- `daravel_redis` queue (list and stream engines): a worker whose reservation ran out while its job ran (a handler that blocked its isolate past `retry_after`) no longer deletes or releases the job another worker has taken since. Its `delete` removed that worker's job, and its `release` queued a second copy that a third worker ran at once. The job's `attempts`, raised by every reservation, now acts as the owner token checked inside the Lua scripts, a release of a job already deleted no longer recreates a hash without a payload, releasing twice queues one copy, and the worker logs one warning per job ("ran past retry_after"). A job hash without its payload is now removed as a `CorruptPayloadException` instead of failing with a type error after every `retry_after`.

### Upgrade notes

- Upgrading can change how the Redis queue treats a stale worker: a `delete` or `release` from a worker whose reservation another worker has taken over does nothing and logs a warning, where it used to act. The guard holds once every worker runs 1.28.0; an older worker sharing the queue still acts as before. When the warning appears, raise `retry_after` above the longest job.
