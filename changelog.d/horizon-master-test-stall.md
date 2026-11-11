### Added

- `daravel_horizon`: `HorizonConfig.check` (boot and `dartisan doctor`) warns when `HORIZON_HEARTBEAT_MS` is under 250 ms outside `APP_ENV=testing`: an idle worker is killed after four silent heartbeats, and a busy host delays heartbeats by a few hundred milliseconds, so healthy workers were killed. The Horizon guide says so.
