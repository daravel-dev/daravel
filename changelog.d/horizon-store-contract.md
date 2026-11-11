### Added

- `daravel_horizon`: `HorizonStore`, the contract of where Horizon keeps what it shows (recorded jobs, monitored tags, metric snapshots), so the coming `database` and `redis` stores (`HORIZON_STORE`) can serve a dashboard in another process. `ProcessHorizonStore` is today's store in the process's coordinator and stays the default; `horizonStoreOf(container)` gives the bound store, else that one. The workers, the master (`HorizonMaster.horizonStore`), the dashboard and `horizon:list`/`horizon:failed` go through it; what they read and write is unchanged.

### Changed

- `daravel_horizon`: the `process` store keeps one record per job uuid: a job recorded again replaces its record (in whichever status), and an older record arriving late from another worker never replaces a newer one. Before, a second record of the same job was listed twice.

### Upgrade notes

- `daravel_horizon`: new public names `HorizonStore`, `ProcessHorizonStore` and `horizonStoreOf` in `package:daravel_horizon` (an application class of one of these names and the barrel import give an ambiguous-import error; `hide` it or rename yours).
