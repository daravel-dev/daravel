### Fixed

- Horizon: an idle worker on a SQLite file queue is given its `busy_timeout` plus two heartbeats before it counts as gone, when that is longer than four heartbeats (7 s at the defaults). A worker waiting for the SQLite write lock sends no heartbeat, and killing it forced a restart of the process. `dartisan horizon` says the lease in its SQLite warning.
- Horizon: a master that runs late (its process busy) does not judge idle workers on that round, at most three rounds in a row, and logs a warning, so a worker whose heartbeats the master has not read yet is not killed for it; a worker that is really gone is still killed at most three heartbeats later.
