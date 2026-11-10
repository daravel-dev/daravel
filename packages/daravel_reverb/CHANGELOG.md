# Changelog

## Unreleased

Not on pub.dev yet: first published with the Daravel release after 1.27.0.

- First release (Blueprint #135, R3): `withReverb()` (`ReverbConfig` from `REVERB_SERVER_*`, `REVERB_APPS`, `REVERB_APPS_PROVIDER`, with its config checks), the application providers `ReverbApps.fromEnv` and `ReverbApps.database()` (`DatabaseAppProvider`, `CreateReverbAppsTable`), and the commands `reverb:start`, `reverb:restart` and `reverb:stats` in `package:daravel_reverb/commands.dart`.
- The `/reverb` dashboard (Blueprint #135, R3b): `withReverb(dashboard: '/reverb', middleware: [...])`, tabs Overview, Limits, Apps and Workers, `GET /reverb/api/stats|apps|stream`, `POST /reverb/api/restart`; `REVERB_METRICS_URL` for a `reverb:start` server apart. `ReverbReport` is in the main library.
