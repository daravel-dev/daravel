### Added

- `JobPushFailedAfterCommit` event and `queue_after_commit_push_failures_total{connection}` on `/metrics`: a job dispatched inside a transaction that could not be pushed after the commit (its unique lock and debounce owner were given back; the error reaches the caller of `transaction()`, logged once).

### Changed

- Inside a transaction, a unique job's lock (and a debounced job's owner) is taken at dispatch, as Laravel's `PendingDispatch::shouldDispatch` does, and given back when the transaction (or the savepoint that dispatched it) rolls back, before a retry of `transaction(attempts:)` runs the body again; only the push waits for the commit (`Queue::enqueueUsing`). Before, the lock was taken at commit, so two transactions dispatching the same id both appeared to succeed and the later one was dropped silently after its commit. A savepoint released and then rolled back with its parent gives its lock back too (Laravel keeps it until `uniqueFor`).

### Upgrade notes

- Inside a transaction, dispatching a unique job whose id is held by another pending dispatch is now refused at dispatch (it was dropped at commit before). New public name `JobPushFailedAfterCommit` in `package:daravel` (an application class of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
