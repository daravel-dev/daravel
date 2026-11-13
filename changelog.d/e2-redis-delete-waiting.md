### Fixed

- `daravel_redis` queue: deleting a job that waits (one `daravel_horizon` quarantines after taking it back from a crashed worker, a delayed job, a released one) removed only its hash: its id stayed in the list, the stream or the delayed set and was counted by `size` (and Horizon's queue sizes) until a pop skipped it. `delete` now removes it from wherever it is; a reserved job, the usual case, costs what it did, and the list is scanned (`LREM`) only for a job that waits there. Every `XADD` now records the stream entry in the job's hash, so an entry not read yet can be deleted.
