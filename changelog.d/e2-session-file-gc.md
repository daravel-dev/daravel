### Added

- `daravel_session`: `SessionGarbageCollector` (`SessionManager.garbageCollector`), which runs the lottery's sweep of expired sessions detached from the request, one at a time per application, with the shutdown waiting for the one in progress; `FileSessionHandler` takes `gcBatch` (2000) and `gcBudget` (250 ms) and reports `gcPosition`.

### Changed

- `daravel_session`: the 2 requests in 100 that win the session lottery no longer wait for the sweep, which held every request of the isolate meanwhile (the `file` driver listed and stat'ed the whole directory synchronously: 50 000 files froze the isolate for about 30 s). The `file` driver now sweeps asynchronously in rounds of at most `gcBatch` files or `gcBudget`, each resuming where the last stopped, and compares modification times with `Clock.now()` in `read` and `gc`.

### Upgrade notes

- Upgrading can change when expired sessions disappear: the sweep runs after the winning request instead of before it, and the `file` driver removes a large backlog over several sweeps rather than in one. Upgrading can also change file-session expiry in tests: it follows `Clock.now()` (`travel()`, `freezeTime()`) instead of the wall clock; a clock moved back expires nothing. New public names in `package:daravel_session`: `SessionGarbageCollector`, `SessionManager.garbageCollector`, `FileSessionHandler.gcBatch`, `gcBudget` and `gcPosition`.
