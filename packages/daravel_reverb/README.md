<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_reverb

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_reverb/README.id.md)

The Pusher-protocol server of [Daravel](https://pub.dev/packages/daravel)
in a process of its own, after Laravel Reverb: `dartisan reverb:start`,
several applications on one server, restarts that spread the reconnects,
and stats per isolate.

`withBroadcasting()` in `package:daravel` already serves Laravel Echo and
pusher-js on the HTTP port; most applications need nothing more. Add this
package for a WebSocket tier of its own, or for several tenants on one
server. The wire format is Pusher 7, unchanged, so Laravel Echo, pusher-js
and Laravel's `pusher` broadcaster connect as they would to Laravel Reverb.

```dart
// bootstrap/app.dart
import 'package:daravel_reverb/daravel_reverb.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withBroadcasting(channels: registerChannels)
    .withReverb(middleware: ['auth', 'can:viewReverb']) // /reverb dashboard
    .create();
```

```dart
// bootstrap/commands.dart
import 'package:daravel_reverb/commands.dart';

final List<CommandFactory> commands = [...reverbCommands];
```

`dartisan pub:add reverb` writes both.

## Commands

| Command | |
| :-- | :-- |
| `reverb:start [--host] [--port] [--path] [--hostname] [--isolates] [--debug]` | Serves the application's broadcasting only (`/app/{key}`, `/apps/{id}/*`, `/broadcasting/auth` with `REVERB_SERVER_AUTH=local`), `/up`, `/up/ready` and `/metrics`, in `REVERB_SERVER_ISOLATES` worker isolates. `--debug` logs every frame, signatures masked. |
| `reverb:restart` | Every `reverb:start` isolate sharing the queue's signal store (`QUEUE_SIGNAL_STORE`) closes its connections over `REVERB_DRAIN_SPREAD` and starts again; clients reconnect with their own backoff. A server of one isolate ends, for its process manager to start it again, as Laravel's. |
| `reverb:stats [--url] [--token] [--json]` | Connections per isolate, channels and messages per application, read from the server's `/metrics` (`METRICS_ENABLED=true`). |

## Configuration

| Variable | Default | |
| :-- | :-- | :-- |
| `REVERB_SERVER_HOST`, `REVERB_SERVER_PORT`, `REVERB_SERVER_PATH` | `0.0.0.0`, `8080`, empty | Where `reverb:start` listens; the path prefixes the Pusher routes (`/ws`). |
| `REVERB_HOST` | | The public host name `reverb:start` prints. |
| `REVERB_SERVER_ISOLATES` | the processors | Worker isolates of `reverb:start`. |
| `REVERB_SERVER_AUTH` | `app` | `app`: the HTTP application answers `/broadcasting/auth`; `local`: `reverb:start` does too, with the same guards. |
| `REVERB_APPS` | empty | A JSON list of applications, entries as in Reverb's `config/reverb.php`: `app_id`, `key`, `secret`, `allowed_origins`, `max_connections`, `max_message_size`, `activity_timeout`, `rate_limiting` (`enabled`, `max_attempts`, `decay_seconds`, `terminate_on_limit`), plus `encryption_master_key` (base64). The application of `REVERB_APP_*` is served beside them. |
| `REVERB_APPS_PROVIDER` | `config` | `config` (`REVERB_APPS`) or `database` (the `reverb_apps` table of `CreateReverbAppsTable`). |
| `REVERB_APPS_CACHE_TTL` | `60s` | How long an isolate keeps a row of `reverb_apps`, found or not. |
| `REVERB_METRICS_URL` | | The `/metrics` of a `reverb:start` server, for the `/reverb` dashboard of the HTTP application; empty: its own. |

The limits of the application of `REVERB_APP_*`, `REVERB_DRAIN_SPREAD` and
`REVERB_PULSE_INGEST_INTERVAL` are `package:daravel`'s, as documented in the
[Broadcasting guide](https://daravel.dev/broadcasting.html). The config
check reports duplicate ids or keys and origins that are not host names,
and warns of secrets under 32 bytes. `toMap()` (and `config:show`) never
holds a secret.

## Dashboard

`/reverb` (`withReverb(dashboard: '/reverb', middleware: [...])`) shows connections per
application and isolate, channels, messages per second, fan-out p50/p95,
refusals and slow consumers, the applications without their secrets, and
a button for `reverb:restart`. Outside `local` and `testing` it answers 403
until `middleware:` guards it. Define the gate in `bootstrap/policies.dart`:
`gate.define('viewReverb', (user, _) => ...)`.

## Several applications

Each application's channels are its own: a client of one never hears
another's events, and a signature made with one application's secret is
refused for another. Clients see plain channel names; inside the server an
application other than the one of `REVERB_APP_*` is kept apart by its id.

```dart
.withReverb(apps: ReverbApps.database()) // or ReverbApps.fromEnv
```

## License

MIT.
