### Added

- `daravel_horizon` dashboard page (H4b): `HORIZON_PATH` and `HORIZON_PATH/{tab}` (`horizon.index`, `horizon.view`) serve one page built with `package:daravel/html.dart` (`horizonPage`, `horizonTabs`): Dashboard, Monitoring, Metrics, Workload, Pending, Completed, Silenced and Failed; its inline style and script carry a fresh CSP nonce, every value is shown as text, the dashboard follows `/horizon/api/stream` and falls back to polling, and Retry sends `X-XSRF-TOKEN` when a session cookie exists. `dartisan horizon --dashboard=[host]:port` serves only the dashboard on a port of its own (`HorizonCommand.serveDashboard`, `HorizonRoutes`). `daravel_pulse`: the Queues card links to the dashboard when a `horizon.index` route exists (`Pulse.horizonPath`).

### Upgrade notes

- `daravel_horizon` (H4b): new public names `HorizonRoutes`, `horizonPage` and `horizonTabs`; `withHorizon()` also serves `HORIZON_PATH` and `HORIZON_PATH/{tab}` (an application route there clashes). `daravel_pulse`: `/pulse/api/stats` gains `horizon_path` (null without Horizon).
