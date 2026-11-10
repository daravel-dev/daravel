### Added

- `daravel_horizon` install and sample (H4c): `dartisan pub:add horizon` adds the dependency, `.withHorizon(createApp: createApp, middleware: ['auth', 'can:viewHorizon'])`, `horizonCommands` (from the new `package:daravel_horizon/commands.dart`) and the `HORIZON_*` lines of `.env.example`, and says how to define the `viewHorizon` gate and schedule `horizon:snapshot`. `apps/horizon_demo`: two supervisors, three jobs (quick, slow, flaky), `POST /demo/dispatch`, embedded or apart (`dartisan horizon --dashboard`), tested in CI.
