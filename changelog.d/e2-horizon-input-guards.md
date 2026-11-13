### Fixed

- Horizon: a negative `starting_at` on the dashboard's job lists (`/horizon/api/jobs/completed?starting_at=-10`) lists from the start. Before, the `process` store (the default) answered an empty list; the `database` store already read it as 0.
- Horizon: `horizon:status`, `horizon:list`, `horizon:supervisors` and `horizon:terminate --wait` report Horizon inactive when the status they read from the signal store is not a state Horizon wrote (not JSON, or fields of other types), instead of failing with a `FormatException` or a type error (`HorizonSignals.status`).
