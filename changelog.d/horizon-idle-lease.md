### Fixed

- Horizon: an idle worker on a SQLite file queue is given its `busy_timeout` plus two heartbeats before it counts as gone, when that is longer than four heartbeats (7 s at the defaults), and at most 10 minutes. A worker waiting for the SQLite write lock sends no heartbeat, and killing it forced a restart of the process. The `busy_timeout` used is the one the connection really has: none on a `file:` URI, and none for a value SQLite does not take. `dartisan horizon` says the lease in its SQLite warning, and the embedded supervisor logs the same note.
- Horizon: a master that runs late (its process busy) does not judge idle workers on that round, at most three rounds in a row, and logs a warning, so a worker whose heartbeats the master has not read yet is not killed for it; a worker that is really gone is still killed at most three lease rounds later, which for a master that stays late is more than three heartbeats. A round counts as late past half a heartbeat and never under 50 ms.

### Upgrade notes

- `HORIZON_HEARTBEAT_MS` below 50 now stops the boot (`config:check` error); 50 to 249 still only warns outside `APP_ENV=testing`. New public names: `HorizonConfig.leastHeartbeat`, `HorizonConfig.minimumLateness`, `HorizonConfig.lateness`, `HorizonConfig.maxSqliteLease`, and `SqliteDriver.appliedBusyTimeout`.
