### Added

- `daravel_session`: `SweepsInRounds`, a `SessionHandler` whose sweep the session middleware runs detached from the request through `SessionGarbageCollector` (`SessionManager.garbageCollector`): one at a time per application, its errors logged, the shutdown waiting for the round in progress. `FileSessionHandler` is one, and takes `gcBatch` (2000) and `gcBudget` (250 ms) and reports `gcPosition`.

### Changed

- `daravel_session`: with the `file` driver, the 2 requests in 100 that win the session lottery no longer wait for the sweep, which held every request of the isolate meanwhile (it listed and stat'ed the whole directory synchronously: 50 000 files froze the isolate for about 30 s). The sweep now runs in the background, asynchronously, in rounds of at most `gcBatch` files or `gcBudget`, each resuming where the last stopped; the file driver compares modification times with `Clock.now()` in `read` and `gc`. The `database`, `cache` and `redis` drivers still sweep in the winning request, inside its transaction.

### Upgrade notes

- Upgrading can change when expired file sessions disappear: the `file` driver's sweep runs after the winning request instead of before it, and a large backlog goes over several sweeps rather than one. Upgrading can also change file-session expiry in tests: it follows `Clock.now()` (`travel()`, `freezeTime()`) instead of the wall clock; a clock moved back expires nothing. New public names in `package:daravel_session`: `SweepsInRounds`, `SessionGarbageCollector`, `SessionManager.garbageCollector`, `FileSessionHandler.gcBatch`, `gcBudget` and `gcPosition`.
