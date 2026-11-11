### Added

- `DB.afterRollback(callback)` / `DatabaseManager.afterRollback` (G1.5, Laravel's `DB::afterRollBack`): runs when the active transaction level rolls back, and before a retry of `transaction(attempts:)` runs the body again, to undo what the body did outside the database (a unique lock taken at dispatch). A released savepoint passes its callbacks to the level around it, so that level's rollback still runs them; Laravel drops them there, Daravel keeps them on purpose. A failing callback is logged, the others still run, and the caller gets the error that caused the rollback.

### Changed

- Every after-commit callback runs even when one throws: each error is logged and the first is rethrown to the caller of `transaction()` once all have run. Before, as in Laravel, the first error stopped the rest, so a job pushed after commit could be lost because an earlier callback failed.
