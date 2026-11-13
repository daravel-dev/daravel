### Added

- `FileStore(isolateLocks:)`: the store holding a lock between the isolates of the process before the lock file is taken for other processes; `CACHE_STORE=file` passes the `process` store. `daravel_mysql`'s `MySqlDriver` reports MySQL's data exceptions (1264, 1292, 1366, 1406, 1690) through `DataExceptionErrors`.

### Fixed

- `Cache.lock` on the `file` store held only within one process: the store's locks went to the `process` store, so two processes sharing `CACHE_PATH` (a `dartisan` command and the server, two servers) both took the same lock, the queue's `queue:retry-all` lock in a `file` signal store included. It now takes the coordinator layer (between the process's isolates; the OS lock of a lock file is the process's on POSIX) and then the lock file (between processes), held only when both took it and released together; a process killed while holding the lock keeps it until its time to live. It costs about 2.5 ms per acquire and release on Linux and 5.5 ms on Windows, where it cost microseconds while it did not hold across processes.
- Database cache store: `increment` and `decrement` of a value that is not a number (a string, `null`, a value Laravel serialized) replaced it with the increment; they now leave it alone and throw a `StateError`, where Laravel's `DatabaseStore` answers `false`. The `memory` and `file` stores still count such a value as 0, as Laravel's array and file stores do.
- Rate limiting on the `database` cache store: a counter the database cannot convert to a number (PostgreSQL `22P02`, MySQL `1292`: another value stored under the key) failed open on every request and reported each one; it now fails open as before and is reported once per key. Other store errors are reported every time, as before.

### Upgrade notes

- Upgrading can change cache behaviour: `Cache.lock` on the `file` store now excludes other processes sharing the directory and costs milliseconds; `increment`/`decrement` on the `database` store throw a `StateError` for a value that is not a number instead of overwriting it; on MySQL, a data exception during route model binding now answers `404` as it does on PostgreSQL. New public names: `FileStore.isolateLocks`, and `MySqlDriver` implements `DataExceptionErrors`.
