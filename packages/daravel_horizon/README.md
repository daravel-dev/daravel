<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_horizon

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_horizon/README.id.md)

Queue supervisors for [Daravel](https://pub.dev/packages/daravel) after
Laravel Horizon: a pool of worker isolates per supervisor, sized by the
load of its queues, on the same `jobs` table a Laravel application uses.

> Work in progress. This release holds the configuration and the
> auto-scaler; the supervisor, its commands and the dashboard come next.

```dart
import 'package:daravel_horizon/daravel_horizon.dart';

const plans = [
  SupervisorPlan(
    name: SupervisorName('supervisor-1'),
    queues: [QueueName('high'), QueueName('default')],
    minProcesses: 1,
    maxProcesses: 8,
  ),
];

final decision = decide(
  ScalingInput(
    plan: plans.first,
    queues: const [QueueLoad(queue: QueueName('high'), size: 120)],
  ),
  const ScalingState(workers: 1),
);
// decision.total, decision.perQueue, decision.shared
```

The auto-scaler is a pure function: per queue it wants
`ceil(Q·T / W + λ·T)` workers (Little's law on the smoothed arrival rate λ
and run time T, W the queue's target wait), clamps the sum to the plan's
bounds, moves at most `balanceMaxShift` per evaluation, and scales down only
after two evaluations in a row in which every queue waited under half its
target. On the database queue, a job the master takes back from a crashed
worker becomes available again at that moment, so its wait counts from the
take-back, not from when it was first pushed.

## Dashboard API

`withHorizon(createApp: createApp)` serves the dashboard's JSON API under
`HORIZON_PATH` (`/horizon/api/...`) with Laravel Horizon's route names:
stats, workload, masters, monitored tags, job and queue metrics, pending, completed, silenced and failed jobs, retry and
retry-all, and `/horizon/api/stream` (server-sent stats and workload every
second). Retry-all (a Daravel addition: Laravel Horizon retries one job at a
time) pushes back at most 1 000 failed jobs or 10 seconds' worth per request
and answers how many `remaining`; the dashboard calls again with the `after`
and `up_to` it got until none are. A retry-all already running answers 409,
and a job whose payload cannot be read stays in `failed_jobs`, listed under
`skipped`. Metric snapshots are taken by the running Horizon:
`dartisan horizon:snapshot` only asks it to, so schedule it every five
minutes.

### Who may open it

As in Laravel Horizon, every request is authorized after its middleware, and
middleware alone never opens the dashboard:

- `APP_ENV=local`: open;
- otherwise `HorizonDashboard.auth(callback)` decides when it is set;
- otherwise the `viewHorizon` gate; without one, 403.

A callback or gate that throws denies the request, and the error is logged.
Without `middleware:`, the dashboard sits behind the `web` group when the
application has one (`withSession()`), so the gate sees the signed-in user:

```dart
gate.define('viewHorizon', (user, _) => user?.authIdentifier == 1);
```

Without sessions there is no user; decide per request instead, for example
on a secret header a proxy adds:

```dart
HorizonDashboard.auth(
  (request) =>
      constantTimeEquals(request.header('x-horizon-key') ?? '', horizonKey),
);
```

`HorizonDashboard.auth` is kept per isolate: call it inside `createApp`
(bootstrap), not in `main()`, so that every worker isolate of the HTTP
server has it; an isolate without it asks the gate.

Job payloads are shown with the keys `LOG_REDACT` names hidden, as in the
logs; a secret kept in a job's own properties is shown as it was stored, so
keep secrets out of job properties.

`middleware: ['web', 'auth']` sends guests to the login page instead of a
403; a `middleware:` entry the application does not register stops the boot.
Behind the `web` group, a POST or DELETE without the XSRF token (retry,
monitoring) answers 419 before the gate is asked, as in Laravel.

## Store

`HORIZON_STORE` says where Horizon keeps the jobs it shows, their counts,
the monitored tags and the snapshots:

| Store | Where | For |
| :-- | :-- | :-- |
| `process` (default) | the coordinator of the process running Horizon | one process: `serve --embed-worker=horizon`, or `dartisan horizon --dashboard=:8090` |
| `database` | the `horizon_*` tables of `CreateHorizonTables` (add it to the migrations), on `HORIZON_STORE_CONNECTION` | a dashboard served by another process than `dartisan horizon` |
| `redis` | `daravel_redis` (`withRedis()`) | the same, on Redis |

The `database` store writes in batches (every 250 ms or 100 jobs), outside
the job's transaction, and at shutdown before the connections close; a record
it has to drop is counted in `horizon_store_dropped_total`. Writes trim (at
most once a second per store) the rows past `HorizonConfig.trim` (completed,
failed, monitored);
`dartisan horizon:prune` trims all, daily. On SQLite it suits development:
SQLite has one writer, so for production with several processes use
PostgreSQL or MySQL, or `redis`. Laravel Horizon keeps its data in Redis and
creates no table, so a database shared with Laravel has no `horizon_*` table
to collide with.

The `redis` store (`HORIZON_STORE=redis`, with `withRedis()` from
`daravel_redis`) writes in the same batches, one Lua script per batch. Its
keys start with `REDIS_PREFIX` and the hash tag `{daravel:horizon}`: on a
Redis Cluster they share one slot, so one node holds Horizon's data, and
Laravel Horizon's own keys are never touched. Every key but the set of
monitored tags expires by itself, so Redis cleans up after a Horizon that
stopped. The job lists keep at most `HORIZON_STORE_MAX_PER_STATUS` jobs per
status (10 000) besides their retention, and the counts behind the rates,
the summary and the metric snapshots are kept apart, so they are never cut
by that limit:

| Jobs a second | Limit | Completed jobs listed | Redis memory of the lists, at most |
| --: | --: | :-- | --: |
| 2 | 10 000 | the full hour (7 200 jobs) | about 15 MB |
| 10 | 10 000 | about 17 minutes | about 15 MB |
| 1 000 | 10 000 | about 10 seconds | about 15 MB |
| 1 000 | 100 000 | about 100 seconds | about 40 MB |

Laravel Horizon lists completed jobs for 60 minutes with no limit on their
number (gigabytes at a high rate), and the `database` store has no limit on
the number either. A record counts once per job and status; that is
remembered with the job, so a duplicate arriving after the job left every
list counts again.

## `retry_after`

The master kills a worker blocked on a job a heartbeat (at least a second)
before the queue may hand the job to another worker, at the moment the queue
driver states (`QueuedJob.reservedUntil`: whole seconds on the database
queue, milliseconds on Redis). The master and its workers must use the same
`QUEUE_RETRY_AFTER`; when they do not, the master uses the earlier and warns.
A worker extends the reservation of a job that keeps running and tells the
master, which follows it: every half of what the master leaves the job, so a
small `retry_after` means frequent writes (3 s on the database queue: two a
second per running job). Not covered: a worker in another process or host
whose clock runs ahead (the margin covers it only while the difference stays
below it), a process suspended past a reservation, and the Redis stream engine
on a server clock that runs fast or jumps ahead.

## License

MIT.
