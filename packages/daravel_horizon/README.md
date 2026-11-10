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
target.

## Dashboard API

`withHorizon(createApp: createApp, middleware: ['auth', 'can:viewHorizon'])`
serves the dashboard's JSON API under `HORIZON_PATH` (`/horizon/api/...`)
with Laravel Horizon's route names: stats, workload, masters, monitored tags,
job and queue metrics, pending, completed, silenced and failed jobs, retry and
retry-all, and `/horizon/api/stream` (server-sent stats and workload every
second). Outside `APP_ENV=local` and `testing` it answers 403 until the
middleware protects it. Metric snapshots are taken by the running Horizon:
`dartisan horizon:snapshot` only asks it to, so schedule it every five
minutes.

## License

MIT.
