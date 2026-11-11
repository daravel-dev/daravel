### Added

- `runDetached(body, name:, stop:)` and `runDetachedAsync(body, name:, stop:)` (Review #149): run work that outlives the request, job or command starting it (a periodic timer, a stream listened to for the life of the process, a loop) in a zone forked from the root that holds only the application's container: no request scope or log context, no cancellation token, no transaction and no query capture of the caller. Errors it leaves uncaught are logged with its name (`Detached task <name> failed`), never handed to the caller's zone; the application stops every such task at shutdown (`DetachedTasks.cancelAll`, at most 2 s, errors while stopping logged at debug). `runDetachedAsync` gives the caller a future of its own zone; wrap it in `SharedResult` when callers of several zones share it.

### Fixed

- Work that a request started lazily no longer lives on in that request's zone (Review #149): the broadcast relay a WebSocket connection starts (`REVERB_SCALING_ENABLED`, database or Redis), the isolate's broadcast receiver its first subscriber opens, the Pusher metrics flush, the rate limiter's lease reaper, database connections and `daravel_redis` connections opened inside a request, and `daravel_redis`'s tiered cache invalidation loop. Their logs no longer carry the first request's `request_id`, their queries no longer count towards that request (`DB.whenQueryingForLongerThan`), a job's cancellation token no longer reaches their transactions, and their errors are logged instead of reaching a handler that finished long ago.

### Changed

- The database connection log lines name the driver after the connection: `Database connection [sqlite] (pgsql) opened.` (and `closed.`), so a connection named `sqlite` that `DB_URL` points at PostgreSQL reads as what it is. Log parsers matching the old text need the new form.

### Upgrade notes

- New public names `runDetached`, `runDetachedAsync`, `Detached`, `DetachedTasks` and `DetachedErrorHandler` in `package:daravel` (an application class of one of these names and the barrel import give an ambiguous-import error; `hide` it or rename yours). The database connection log text changed (above).
