import 'package:daravel/daravel.dart';

/// A supervisor's name (`supervisor-1`), as in `config/horizon.php`.
extension type const SupervisorName(String value) implements String {}

/// A queue's name (`default`).
extension type const QueueName(String value) implements String {}

/// How a supervisor spreads its workers over its queues (Horizon's
/// `balance`).
enum BalanceStrategy {
  /// Every worker polls every queue, in priority order
  /// (`queue:work --queue=a,b`).
  off,

  /// `maxProcesses` workers, split evenly between the queues.
  simple,

  /// Workers follow the load ([AutoScalingStrategy]).
  auto,
}

/// What `BalanceStrategy.auto` sizes the pool by (Horizon's
/// `autoScalingStrategy`).
enum AutoScalingStrategy {
  /// Enough workers to drain the backlog within the queue's wait threshold
  /// and serve what arrives (Little's law, on smoothed rates).
  time,

  /// One worker per `HORIZON_JOBS_PER_PROCESS` waiting jobs.
  size,
}

/// One supervisor: a pool of worker isolates on some queues of one
/// connection (an entry of `defaults` in `config/horizon.php`).
final class SupervisorPlan {
  /// A supervisor named [name].
  const SupervisorPlan({
    required this.name,
    this.connection,
    this.queues = const [QueueName('default')],
    this.balance = BalanceStrategy.auto,
    this.autoScalingStrategy = AutoScalingStrategy.time,
    this.minProcesses = 1,
    this.maxProcesses = 1,
    this.balanceMaxShift = 1,
    this.balanceCooldown = const Duration(seconds: 3),
    this.maxTime,
    this.maxJobs,
    this.tries,
    this.backoff,
    this.timeout,
    this.sleep = const Duration(seconds: 3),
    this.nice = 0,
  });

  /// The supervisor's name.
  final SupervisorName name;

  /// The queue connection; `QUEUE_CONNECTION` when null.
  final String? connection;

  /// The queues, in priority order.
  final List<QueueName> queues;

  /// How workers are spread over [queues].
  final BalanceStrategy balance;

  /// What [BalanceStrategy.auto] sizes the pool by.
  final AutoScalingStrategy autoScalingStrategy;

  /// The fewest workers (0: none while every queue is empty).
  final int minProcesses;

  /// The most workers.
  final int maxProcesses;

  /// The most workers added or removed per evaluation.
  final int balanceMaxShift;

  /// How often the pool is evaluated.
  final Duration balanceCooldown;

  /// A worker is replaced after this long (`--max-time`).
  final Duration? maxTime;

  /// A worker is replaced after this many jobs (`--max-jobs`).
  final int? maxJobs;

  /// Overrides the jobs' `tries`.
  final int? tries;

  /// Overrides the jobs' backoff.
  final List<Duration>? backoff;

  /// Overrides the jobs' timeout.
  final Duration? timeout;

  /// The wait of an idle worker between polls.
  final Duration sleep;

  /// Horizon's `nice`: accepted for parity, with no effect on isolates.
  final int nice;

  /// The plan as a map (`config:show`).
  Map<String, Object?> toMap() => <String, Object?>{
    'name': name.value,
    'connection': connection,
    'queue': [for (final q in queues) q.value],
    'balance': balance.name,
    'autoScalingStrategy': autoScalingStrategy.name,
    'minProcesses': minProcesses,
    'maxProcesses': maxProcesses,
    'balanceMaxShift': balanceMaxShift,
    'balanceCooldown': balanceCooldown.inSeconds,
    'maxTime': maxTime?.inSeconds,
    'maxJobs': maxJobs,
    'tries': tries,
    'backoff': backoff == null ? null : [for (final b in backoff!) b.inSeconds],
    'timeout': timeout?.inSeconds,
    'sleep': sleep.inSeconds,
    'nice': nice,
  };
}

/// How long Horizon keeps what it records (Horizon's `trim`).
final class HorizonTrim {
  /// Recent, pending and completed jobs for an hour; failed and monitored
  /// ones for a week.
  const HorizonTrim({
    this.recent = const Duration(minutes: 60),
    this.pending = const Duration(minutes: 60),
    this.completed = const Duration(minutes: 60),
    this.recentFailed = const Duration(days: 7),
    this.failed = const Duration(days: 7),
    this.monitored = const Duration(days: 7),
  });

  /// Recent jobs.
  final Duration recent;

  /// Pending jobs.
  final Duration pending;

  /// Completed jobs.
  final Duration completed;

  /// Recently failed jobs.
  final Duration recentFailed;

  /// Failed jobs.
  final Duration failed;

  /// Jobs of monitored tags.
  final Duration monitored;

  /// In minutes, as `config/horizon.php` writes them.
  Map<String, Object?> toMap() => <String, Object?>{
    'recent': recent.inMinutes,
    'pending': pending.inMinutes,
    'completed': completed.inMinutes,
    'recent_failed': recentFailed.inMinutes,
    'failed': failed.inMinutes,
    'monitored': monitored.inMinutes,
  };
}

/// The `HORIZON_*` settings and the supervisors (Laravel Horizon's
/// `config/horizon.php`): scalars from `.env`, plans in Dart.
final class HorizonConfig implements ConfigSection {
  /// Horizon's settings; usually [HorizonConfig.fromEnv].
  const HorizonConfig({
    this.enabled = true,
    this.name,
    this.path = '/horizon',
    this.store = 'process',
    this.storeConnection,
    this.plans = const [SupervisorPlan(name: SupervisorName('supervisor-1'))],
    this.waits = const {'database:default': Duration(seconds: 60)},
    this.trim = const HorizonTrim(),
    this.silenced = const <String>[],
    this.silencedTags = const <String>[],
    this.fastTermination = false,
    this.memoryLimit = 0,
    this.killGrace = const Duration(seconds: 10),
    this.heartbeat = const Duration(seconds: 1),
    this.ewmaAlpha = 0.3,
    this.jobsPerProcess = 100,
    this.quarantineAfter = 2,
  });

  /// The settings in `HORIZON_*`, with the supervisors of [defaults], each
  /// replaced by the one of the same name in `environments[APP_ENV]` and
  /// joined by the others there (Laravel's `defaults` and `environments`).
  factory HorizonConfig.fromEnv(
    Env env, {
    List<SupervisorPlan> defaults = const [
      SupervisorPlan(name: SupervisorName('supervisor-1')),
    ],
    Map<String, List<SupervisorPlan>> environments = const {},
    Map<String, Duration>? waits,
  }) => HorizonConfig(
    enabled: env.boolean('HORIZON_ENABLED', true),
    name: env.maybeString('HORIZON_NAME'),
    path: env.string('HORIZON_PATH', '/horizon'),
    store: env.string('HORIZON_STORE', 'process'),
    storeConnection: env.maybeString('HORIZON_STORE_CONNECTION'),
    plans: resolvePlans(
      defaults,
      environments[env.string('APP_ENV', 'production')] ?? const [],
    ),
    waits: waits ?? const {'database:default': Duration(seconds: 60)},
    fastTermination: env.boolean('HORIZON_FAST_TERMINATION', false),
    memoryLimit: env.integer('HORIZON_MEMORY_LIMIT', 0),
    killGrace: Duration(seconds: env.integer('HORIZON_KILL_GRACE', 10)),
    heartbeat: Duration(
      milliseconds: env.integer('HORIZON_HEARTBEAT_MS', 1000),
    ),
    ewmaAlpha: double.tryParse(env.string('HORIZON_EWMA_ALPHA', '0.3')) ?? 0.3,
    jobsPerProcess: env.integer('HORIZON_JOBS_PER_PROCESS', 100),
    quarantineAfter: env.integer('HORIZON_QUARANTINE_AFTER', 2),
  );

  /// [defaults] with each plan of [overrides] put in place of the one of the
  /// same name, or added after them.
  static List<SupervisorPlan> resolvePlans(
    List<SupervisorPlan> defaults,
    List<SupervisorPlan> overrides,
  ) {
    final byName = {for (final plan in defaults) plan.name.value: plan};
    for (final plan in overrides) {
      byName[plan.name.value] = plan;
    }
    return List.unmodifiable(byName.values);
  }

  /// `false` runs no supervisor and answers 404 on the dashboard
  /// (`HORIZON_ENABLED`).
  final bool enabled;

  /// Shown in the dashboard and notifications (`HORIZON_NAME`).
  final String? name;

  /// The dashboard's path (`HORIZON_PATH`).
  final String path;

  /// Where Horizon keeps what it records (`HORIZON_STORE`): `process`
  /// (the coordinator, one process), `database` or `redis`.
  final String store;

  /// The connection of a `database` or `redis` store
  /// (`HORIZON_STORE_CONNECTION`).
  final String? storeConnection;

  /// The supervisors, resolved for `APP_ENV`.
  final List<SupervisorPlan> plans;

  /// `connection:queue` → the wait past which `LongWaitDetected` fires, and
  /// the target wait of [AutoScalingStrategy.time].
  final Map<String, Duration> waits;

  /// How long records are kept.
  final HorizonTrim trim;

  /// Job names not listed as completed.
  final List<String> silenced;

  /// Jobs with these tags are not listed as completed.
  final List<String> silencedTags;

  /// `horizon:terminate` returns before the workers finished
  /// (`HORIZON_FAST_TERMINATION`).
  final bool fastTermination;

  /// Workers are replaced one by one once the process's resident memory
  /// passes this many megabytes (`HORIZON_MEMORY_LIMIT`, 0 for none). Isolates
  /// share one heap, so this is the process's, not a worker's.
  final int memoryLimit;

  /// A job running this long past its timeout has its isolate killed
  /// (`HORIZON_KILL_GRACE`, seconds).
  final Duration killGrace;

  /// How often workers report to the supervisor (`HORIZON_HEARTBEAT_MS`).
  final Duration heartbeat;

  /// The smoothing of arrival rates and service times
  /// (`HORIZON_EWMA_ALPHA`, 0.3).
  final double ewmaAlpha;

  /// Waiting jobs per worker of [AutoScalingStrategy.size]
  /// (`HORIZON_JOBS_PER_PROCESS`, 100).
  final int jobsPerProcess;

  /// A job that brought its worker down this many times in a row is moved
  /// to `failed_jobs` (`HORIZON_QUARANTINE_AFTER`, 2).
  final int quarantineAfter;

  /// The target wait of [queue] on [connection]: its [waits] entry, or 60 s.
  Duration waitFor(String connection, String queue) =>
      waits['$connection:$queue'] ?? const Duration(seconds: 60);

  @override
  String get key => 'horizon';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'enabled': enabled,
    'name': name,
    'path': path,
    'store': store,
    'store_connection': storeConnection,
    'defaults': [for (final plan in plans) plan.toMap()],
    'waits': {
      for (final MapEntry(:key, :value) in waits.entries) key: value.inSeconds,
    },
    'trim': trim.toMap(),
    'silenced': silenced,
    'silenced_tags': silencedTags,
    'fast_termination': fastTermination,
    'memory_limit': memoryLimit,
    'kill_grace': killGrace.inSeconds,
    'heartbeat_ms': heartbeat.inMilliseconds,
    'ewma_alpha': ewmaAlpha,
    'jobs_per_process': jobsPerProcess,
    'quarantine_after': quarantineAfter,
  };

  /// Problems `ConfigValidator` reports: bounds of each plan, plan names
  /// used twice, [waits] for queues no plan works, and the store.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final horizon = config.section<HorizonConfig>();
    final issues = <ConfigIssue>[];
    final names = <String>{};
    final worked = <String>{};
    final defaultConnection = config.section<QueueConfig>().defaultConnection;
    for (final plan in horizon.plans) {
      if (!names.add(plan.name.value)) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'Horizon supervisor [${plan.name.value}] is defined twice.',
          ),
        );
      }
      if (plan.minProcesses < 0) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'Horizon supervisor [${plan.name.value}]: minProcesses must be 0 '
            'or more.',
          ),
        );
      }
      final floor = plan.minProcesses < 1 ? 1 : plan.minProcesses;
      if (plan.maxProcesses < floor) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'Horizon supervisor [${plan.name.value}]: maxProcesses '
            '(${plan.maxProcesses}) must be at least $floor.',
          ),
        );
      }
      if (plan.balanceMaxShift < 1) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'Horizon supervisor [${plan.name.value}]: balanceMaxShift must '
            'be at least 1.',
          ),
        );
      }
      if (plan.queues.isEmpty) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'Horizon supervisor [${plan.name.value}] has no queues.',
          ),
        );
      }
      for (final queue in plan.queues) {
        worked.add('${plan.connection ?? defaultConnection}:${queue.value}');
      }
    }
    for (final queue in horizon.waits.keys) {
      if (!worked.contains(queue)) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.warning,
            'Horizon waits names [$queue], which no supervisor works.',
          ),
        );
      }
    }
    if (!const {'process', 'database', 'redis'}.contains(horizon.store)) {
      issues.add(
        ConfigIssue(
          ConfigIssueLevel.error,
          'HORIZON_STORE=${horizon.store} is not a Horizon store (process, '
          'database, redis).',
        ),
      );
    }
    if (horizon.ewmaAlpha <= 0 || horizon.ewmaAlpha > 1) {
      issues.add(
        const ConfigIssue(
          ConfigIssueLevel.error,
          'HORIZON_EWMA_ALPHA must be above 0 and at most 1.',
        ),
      );
    }
    return issues;
  }
}
