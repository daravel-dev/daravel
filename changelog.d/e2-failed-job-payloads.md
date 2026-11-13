### Fixed

- A queued job whose payload does not decode is recorded in `failed_jobs` whatever the payload is: not JSON, empty, JSON that is not an object, or an object without a text `uuid` (a new uuid is given then). Before, a payload that was not JSON or was empty made the failed job provider (`DatabaseFailedJobProvider`, `MemoryFailedJobProvider`) throw after the Redis queue had already removed the job, so it was gone without a trace. The database queue was not affected: it leaves a payload that is not a Daravel job to the Laravel workers that may share the table.
