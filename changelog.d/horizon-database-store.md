### Added

- `daravel_horizon`: the `database` store (`HORIZON_STORE=database`, `HORIZON_STORE_CONNECTION`): `DatabaseHorizonStore` keeps the jobs Horizon shows, their counts, the monitored tags and the metric snapshots in the tables of `CreateHorizonTables` (`horizon_jobs`, `horizon_job_counts`, `horizon_job_tags`, `horizon_monitored_tags`, `horizon_snapshots`; add it to the migrations, as `CreateSessionsTable`), so a dashboard served by another process than `dartisan horizon` shows what its workers recorded. Records are buffered per isolate and written in batches (every 250 ms or 100 jobs) outside the job's transaction, the newest record of a job winning when two workers write it at once; the buffer is written at shutdown, before the connections close; a record dropped (buffer full, store closed, database failing) is counted in `horizon_store_dropped_total{store,reason}` and logged at most once a minute. Writes trim up to 100 rows past their retention, at most once a second per store (`HorizonConfig.trim`: completed, failed, monitored), portably across SQLite, PostgreSQL and MySQL; `dartisan horizon:prune` trims all. Laravel Horizon keeps its data in Redis and creates no table, so a database shared with Laravel has no `horizon_*` table to collide with.
- `dartisan horizon` warns when it runs with `HORIZON_STORE=process` and serves no dashboard of its own (`--dashboard`): a dashboard in another process would show nothing.

### Changed

- `daravel_horizon`: `withHorizon()` builds the store at boot, so a `HORIZON_STORE` that cannot be built (such as `redis` without `daravel_redis`'s `withRedis()`) stops the boot with a configuration error instead of failing later.

### Upgrade notes

- `daravel_horizon`: new public names `CreateHorizonTables`, `DatabaseHorizonStore`, `HorizonStoreDrop` and `HorizonPruneCommand` in `package:daravel_horizon` (an application class of one of these names and the barrel import give an ambiguous-import error; `hide` it or rename yours).
