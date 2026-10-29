# Pulse

`daravel_pulse` serves a dashboard, from your application, of what it is
doing: how many requests it answers and how fast, which routes are slow,
which queries are slow, which exceptions it throws, how long the queues are
and which jobs fail. It follows Laravel Pulse, without a database of its
own or an external service: every worker isolate records in memory, and the
page merges them.

```bash
dartisan pub:add pulse
```

`pub:add` adds the dependency, the `.withPulse()` call below (without
middleware: add it before the page leaves local) and the `PULSE_*` settings
to `.env.example`. With `dart pub add daravel_pulse` you register it
yourself:

```dart
// bootstrap/app.dart
import 'package:daravel_pulse/daravel_pulse.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withPulse(middleware: ['auth', 'can:viewPulse'])
    // ...
    .create();
```

The dashboard is at `/pulse` (`PULSE_PATH`, or `withPulse(path:
'/admin/pulse')`). It refreshes every five seconds and shows the last hour,
6 hours or 24 hours.

## Who can see it

Outside `APP_ENV=local` and `testing` the dashboard answers 403 until
`withPulse` is given middleware, such as `auth` and the gate Laravel Pulse
uses:

```dart
// bootstrap/policies.dart
gate.define('viewPulse', (user, args) => user is User && user.isAdmin);
```

`PULSE_ENABLED=false` records nothing and answers 404.

## What it shows

- **Requests.** The count, server errors (5xx), slow requests and the
  average time, with a chart of the period. The dashboard's own polling is
  not counted.
- **Slow requests.** Grouped by route pattern (`/users/{id}`, never the raw
  path), with their count and the slowest.
- **Slow queries.** Grouped by SQL and connection. The bindings are never
  kept, so the values in a `where` do not reach the page.
- **Exceptions.** Server errors grouped by class and by the first frame in
  your code, with the latest message and stack trace. 4xx responses
  (validation, not found, forbidden) are not exceptions here.
- **Queues and jobs.** The pending jobs of each queue in `PULSE_QUEUES`, the
  `failed_jobs` rows of the period (from every worker process, as they come
  from the table), and the slow or failed jobs this server's isolates ran.
- **Workers.** Each isolate, the requests it answered, those in flight, and
  the process's memory.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `PULSE_ENABLED` | `true` | `false`: nothing recorded, 404 |
| `PULSE_PATH` | `/pulse` | The dashboard's path |
| `PULSE_SLOW_REQUESTS_THRESHOLD` | `1000` | Milliseconds from which a request is listed |
| `PULSE_SLOW_QUERIES_THRESHOLD` | `1000` | Milliseconds from which a query is listed |
| `PULSE_SLOW_JOBS_THRESHOLD` | `1000` | Milliseconds from which a job is listed |
| `PULSE_QUEUES` | `default` | Queues of the default connection whose size is shown |
| `PULSE_PUBLISH_SECONDS` | `5` | How often a worker sends its report, under a supervisor |

The threshold keys are Laravel Pulse's, so one `.env` serves both.

## How it works

Each isolate keeps a `PulseRecorder`: request counts by minute, and the
slow requests, slow queries, exceptions and jobs in ten-minute buckets,
grouped (at most 50 groups of a kind per bucket), for 24 hours. Memory stays
bounded however busy the server is.

With `APP_ISOLATES` above 1, an isolate that recorded something sends its
report to the coordinator a few seconds later (`PULSE_PUBLISH_SECONDS`), and
the isolate answering the dashboard merges every worker's latest report
with its own. A worker that crashes takes its report with it. Data lives in
the process: a restart starts from zero, and two servers behind a load
balancer each show their own. For history across restarts and servers,
export `/metrics` to Prometheus ([Operations](operations.md)).

Laravel Pulse stores its data in `pulse_*` tables; Daravel's is not
compatible with them, so a Laravel application sharing the database keeps
its own dashboard.
