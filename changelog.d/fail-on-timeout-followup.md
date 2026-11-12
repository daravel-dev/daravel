### Fixed

- `daravel_horizon`: the timeout mark of a job whose worker the master killed is removed only once the job has failed (`JobFailed`, after its `failed_jobs` row), not when failing it threw. Before, a failure to record it (`failed_jobs` not writable, a delete that failed) removed the mark, and the job ran again at its next reservation instead of failing. The master also judges the `retry_after` window once for the mark and the reclaim, so a window passing between the two no longer leaves a job that should fail unmarked.
