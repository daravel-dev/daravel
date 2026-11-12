import 'dart:async';
import 'dart:io' show ProcessInfo;
import 'dart:isolate';

import 'package:daravel/daravel.dart';

import 'auto_scaler.dart';
import 'config.dart';
import 'messages.dart';
import 'signals.dart';
import 'store/horizon_store.dart';
import 'worker_isolate.dart';

/// A worker isolate as the master sees it.
final class HorizonWorker {
  HorizonWorker._(this.name, this.plan);

  /// `horizon-<plan>-<n>`.
  final String name;

  /// Its supervisor.
  final SupervisorPlan plan;

  Isolate? _isolate;
  SendPort? _port;
  final Completer<void> _exited = Completer<void>();

  /// Whether it said [Exited] before it went (a clean exit).
  bool _saidExited = false;

  /// The queues it was last assigned, comma separated.
  String queues = '';

  /// The last heartbeat (wall clock), or the spawn time before one.
  DateTime lastSeen = DateTime.now();

  /// Its last [Heartbeat].
  Heartbeat? last;

  /// The server sessions of its database connections, as last reported
  /// ([encodeSessions]).
  String sessions = '';

  /// Set once its sessions were ended after a kill or crash.
  Future<void>? _sessionsEnded;

  /// Whether it was asked to stop.
  bool stopping = false;

  /// Whether it booted (the lease applies from then on).
  bool ready = false;

  /// Whether it is being replaced for memory (a fresh one follows).
  bool recycling = false;

  /// The reclaim of its job after a lease kill, if one ran.
  Future<bool>? _reclaim;

  /// Whether the master killed it for running past its job's timeout: the
  /// job's attempt failed, which is not a crash.
  bool _timedOut = false;

  /// Whether its job was left to `retry_after` rather than reclaimed (too
  /// late: another worker may hold it already).
  bool _leftToRetryAfter = false;

  /// Whether reclaiming its job threw (the job stays reserved until
  /// `retry_after`).
  bool _reclaimFailed = false;

  /// Whether it runs a job now.
  bool get busy => last?.jobId != null;

  /// Completes when the isolate is gone.
  Future<void> get exited => _exited.future;

  void _send(WorkerCommand command) => _port?.send(command);
}

/// Told about what the master does: `WorkerKilled` reasons and scaling.
typedef HorizonEventSink = void Function(
  String event,
  Map<String, Object?> data,
);

/// Runs the supervisors of [config] (Blueprint #134 §3.4): a pool of worker
/// isolates per plan, sized by the auto-scaler ([decide]) every
/// `balanceCooldown`, each worker polling the queues its share says.
///
/// An idle worker that stops sending heartbeats for three intervals is
/// killed (its lease). A worker running a job is judged by that job's
/// contract instead, since synchronous work blocks its heartbeats too: it
/// is killed once the job runs past the timeout the processor enforces
/// plus `killGrace` (a margin before `retry_after` at the latest), the
/// attempt counted as timed out and the job made available at once
/// ([ReclaimableQueueDriver]; left to `retry_after` when that close to it); a job with no tries left then fails on its
/// next pop, as after any timeout. Only a worker that goes down on its
/// own while running a job counts towards quarantine (`quarantineAfter`).
/// Workers that exit are started again, after a backoff when they crashed.
/// [stop] drains.
final class HorizonMaster {
  /// A master of [config]'s plans, building worker applications with
  /// [factory]; [driver] and [defaultConnection] are where it reads queue
  /// sizes and reclaims jobs.
  HorizonMaster(
    this.factory,
    this.config, {
    required this.driver,
    required this.logger,
    this.coordinator,
    this.store,
    HorizonStore? horizonStore,
    this.failedJobs,
    this.signals,
    this.name = 'horizon',
    this.onTerminate,
    this.restartAfterKill,
    this.onRestartNeeded,
    this.terminateSession,
    this.workerIdleTransactionTimeout,
    this.onEvent,
    this.failsAfterTimeout,
    Duration Function(int crashes)? crashDelay,
  }) : _crashDelay = crashDelay ?? _defaultCrashDelay,
       horizonStore =
           horizonStore ??
           (store == null ? null : ProcessHorizonStore(() => store));

  /// Builds each worker's application (`createApp`, top-level).
  final ApplicationFactory factory;

  /// The plans and limits.
  final HorizonConfig config;

  /// The queue connection of a plan (`null`: the default one).
  final QueueDriver Function(String? connection) driver;

  /// Logs spawns, crashes and kills.
  final Logger logger;

  /// The process's coordinator, shared with the workers.
  final SendPort? coordinator;

  /// The coordinator of the `process` store ([ProcessHorizonStore]), when
  /// no [horizonStore] is given. Without either, no rate is measured.
  final CoordinatorChannel? store;

  /// Where the rates of the auto-scaler come from and where snapshots are
  /// taken: the store the workers record into (`HORIZON_STORE`), else the
  /// `process` store behind [store].
  final HorizonStore? horizonStore;

  /// Where a quarantined job is recorded (`failed_jobs`).
  final FailedJobProvider? failedJobs;

  /// Where `horizon:pause`, `horizon:continue` and `horizon:terminate` are
  /// read from (`QueueManager.signalStore`); none without it.
  final CacheRepository? signals;

  /// This Horizon's name in [HorizonSignals] (`HORIZON_NAME`).
  final String name;

  /// Called after `horizon:terminate` stopped the workers.
  final void Function()? onTerminate;

  /// Why a kill needs a fresh process, or null when it does not: `sqlite_lock`
  /// for a SQLite file queue ([HorizonConfig.onSqliteFile]), whose write
  /// lock a killed worker keeps, or `sessions_not_terminable` for a
  /// database whose driver cannot end a killed worker's sessions
  /// ([SessionTerminatingDriver]). After the first kill the master calls
  /// [onRestartNeeded] once (`dartisan horizon` drains and exits 75).
  final String? restartAfterKill;

  /// Called once after the first kill when [restartAfterKill] is set.
  final void Function()? onRestartNeeded;

  bool _restartRequested = false;

  /// Ends a server session (`connection`, `id`) a killed worker reported
  /// ([Heartbeat.sessions]), so the server rolls back what it left open
  /// before the job is reclaimed; `false` when the server knew no such
  /// session. Without it, sessions are left to the server's
  /// `DB_IDLE_TRANSACTION_TIMEOUT`.
  final Future<bool> Function(String connection, String id)? terminateSession;

  /// `DB_IDLE_TRANSACTION_TIMEOUT` for the workers' applications
  /// ([HorizonConfig.workerIdleTransactionTimeout]); null leaves theirs.
  final Duration? workerIdleTransactionTimeout;

  /// Told about kills and scaling decisions.
  final HorizonEventSink? onEvent;

  /// Whether a job whose worker was killed past its timeout fails now
  /// (`JobProcessor.failsAfterTimeout`, the rule `queue:work` applies to
  /// its own timeouts): it reads the job's retry settings and the
  /// `job-exceptions:<uuid>` count only. That count lives in the queue's
  /// unique-lock store (`QUEUE_UNIQUE_LOCK_STORE`: `database`, `redis` or
  /// `process` by default), which the master and the workers of a process
  /// share; an isolate-scoped `memory` store would count apart in each
  /// isolate, as it already does between workers.
  /// Without it, every such job is made available again.
  final Future<bool> Function(JobPayload payload, int attempts, {int? tries})?
  failsAfterTimeout;

  /// The least time between two `LongWaitDetected` of one queue.
  static const Duration longWaitEvery = Duration(minutes: 5);

  /// When each `connection:queue` last had a `LongWaitDetected` (wall
  /// clock).
  final Map<String, DateTime> _longWaits = {};

  final Duration Function(int crashes) _crashDelay;

  static Duration _defaultCrashDelay(int crashes) =>
      crashes > 5 ? const Duration(minutes: 1) : Duration(seconds: crashes);

  final Map<String, List<HorizonWorker>> _pools = {};
  final Map<String, ScalingState> _states = {};
  final Map<String, int> _next = {};
  final Map<String, List<DateTime>> _crashes = {};
  final List<Timer> _timers = [];
  final ReceivePort _reports = ReceivePort();
  bool _stopping = false;
  bool _paused = false;

  /// The workers of [plan] now.
  List<HorizonWorker> workers(String plan) =>
      List.unmodifiable(_pools[plan] ?? const <HorizonWorker>[]);

  /// The last scaling state of [plan].
  ScalingState? state(String plan) => _states[plan];

  /// Starts every plan at `minProcesses` and its timers.
  Future<void> start() async {
    _reports.listen(_onReport);
    for (final plan in config.plans) {
      _pools[plan.name.value] = [];
      _states[plan.name.value] = const ScalingState();
      await _resize(plan, plan.minProcesses, _spreadAll(plan));
      if (plan.balance == BalanceStrategy.auto) {
        _timers.add(
          Timer.periodic(plan.balanceCooldown, (_) => unawaited(_tick(plan))),
        );
      } else {
        await balance(plan);
      }
    }
    _timers.add(Timer.periodic(config.heartbeat, (_) => _checkLeases()));
    if (signals != null) {
      // Commands sent before this master started are not its own.
      _signalAt = (await _readSignal())?.$2 ?? 0;
      _timers.add(
        Timer.periodic(const Duration(seconds: 1), (_) {
          // A read slower than a second must not let a second poll read the
          // same command and run it again.
          if (_polling) {
            return;
          }
          _polling = true;
          unawaited(_poll().whenComplete(() => _polling = false));
        }),
      );
      // Its state, for `horizon:status` and `horizon:list` in any process
      // that shares the store.
      await _publishStatus();
      _timers.add(
        Timer.periodic(HorizonSignals.statusEvery, (_) {
          // A slow store gets one status at a time, not a pile of them.
          if (_publishing) {
            return;
          }
          _publishing = true;
          unawaited(_publishStatus().whenComplete(() => _publishing = false));
        }),
      );
    }
    if (config.memoryLimit > 0) {
      _timers.add(Timer.periodic(memoryCheck, (_) => _checkMemory(_rss())));
    }
  }

  // -- Commands from other processes (HorizonSignals) --------------------

  int _signalAt = 0;

  /// Whether a poll of the signal store is under way.
  bool _polling = false;

  /// Whether a status publish is under way.
  bool _publishing = false;

  /// The plans whose periodic evaluation is under way.
  final Set<String> _balancing = {};

  /// The periodic evaluation of [plan]: skipped while the previous one
  /// still runs (a queue slower than the cooldown), since two evaluations
  /// read the same pool and would both resize it.
  Future<void> _tick(SupervisorPlan plan) async {
    final name = plan.name.value;
    if (!_balancing.add(name)) {
      return;
    }
    try {
      await balance(plan);
    } on Object catch (e) {
      logger.warning('Horizon could not balance [$name]: $e');
    } finally {
      _balancing.remove(name);
    }
  }

  Future<(String, int)?> _readSignal() async {
    try {
      return await HorizonSignals.read(signals, name);
    } on Object catch (e) {
      logger.warning('Could not read the Horizon signal: $e');
      return null;
    }
  }

  Future<void> _poll() async {
    final signal = await _readSignal();
    if (signal == null || signal.$2 <= _signalAt || _stopping) {
      return;
    }
    _signalAt = signal.$2;
    logger.info('Horizon command: ${signal.$1}.');
    switch (signal.$1) {
      case 'pause':
        pause();
      case 'continue':
        resume();
      case final String command when command.startsWith('pause-supervisor:'):
        pauseSupervisor(command.substring('pause-supervisor:'.length));
      case final String command when command.startsWith('continue-supervisor:'):
        resumeSupervisor(command.substring('continue-supervisor:'.length));
      case 'terminate':
        await stop();
        onTerminate?.call();
      case 'snapshot':
        // horizon:snapshot: the store lives in this process's coordinator.
        await snapshot();
    }
  }

  /// Takes a metric snapshot in the store (`horizon:snapshot`).
  Future<void> snapshot() async {
    try {
      await horizonStore?.snapshot();
    } on Object catch (e) {
      logger.warning('Horizon snapshot failed: $e');
    }
  }

  /// The state [HorizonSignals.status] reads: running or paused, and the
  /// workers of each supervisor.
  Map<String, Object?> status() => <String, Object?>{
    'state': _stopping ? 'inactive' : (_paused ? 'paused' : 'running'),
    'at': DateTime.now().millisecondsSinceEpoch,
    'supervisors': {
      for (final MapEntry(key: plan, value: pool) in _pools.entries)
        plan: [
          for (final w in pool)
            {
              'name': w.name,
              'queues': w.queues,
              'processed': w.last?.processed ?? 0,
              'busy': w.busy,
              // Running a job that blocks its event loop: not reporting,
              // but not lost (it is judged by the job's timeout).
              if (w.busy && _silentFor(w) > config.heartbeat * 2)
                'silentMs': _silentFor(w).inMilliseconds,
              if (w.stopping) 'stopping': true,
            },
        ],
    },
    if (_timeouts.isNotEmpty) 'timedOut': [..._timeouts],
  };

  Duration _silentFor(HorizonWorker w) => DateTime.now().difference(w.lastSeen);

  /// The last jobs whose worker the master killed for their timeout
  /// (newest last), for `horizon:status`.
  final List<Map<String, Object?>> _timeouts = [];

  Future<void> _publishStatus() async {
    try {
      await HorizonSignals.publishStatus(signals, name, status());
    } on Object catch (e) {
      logger.warning('Could not publish the Horizon status: $e');
    }
  }

  // -- Memory (HORIZON_MEMORY_LIMIT) --------------------------------------

  /// How often the process's memory is compared with `memoryLimit`.
  static const Duration memoryCheck = Duration(seconds: 5);

  /// The process's resident memory; replaceable for tests.
  int Function() rssReader = _defaultRss;

  static int _defaultRss() {
    try {
      return ProcessInfo.currentRss;
    } on Object {
      return 0;
    }
  }

  int _rss() => rssReader();

  /// Past `memoryLimit` megabytes of resident memory (the process's: worker
  /// isolates share one heap), replaces one worker, an idle one first, with
  /// a fresh one on the same queues; the next only once it is gone.
  void _checkMemory(int rss) {
    if (_stopping ||
        rss < config.memoryLimit * 1024 * 1024 ||
        _pools.values.any((pool) => pool.any((w) => w.recycling))) {
      return;
    }
    final candidates = [
      for (final pool in _pools.values)
        for (final w in pool)
          if (!w.stopping && w.ready) w,
    ]..sort((a, b) => (a.busy ? 1 : 0).compareTo(b.busy ? 1 : 0));
    if (candidates.isEmpty) {
      return;
    }
    final w = candidates.first
      ..recycling = true
      ..stopping = true;
    w._send(const Stop());
    onEvent?.call('SupervisorLooped', {
      'plan': w.plan.name.value,
      'reason': 'memory',
      'worker': w.name,
      'rss': rss,
    });
  }

  /// Every queue of [plan] for each of [count] workers.
  List<String> _spreadAll(SupervisorPlan plan) => [
    [for (final q in plan.queues) q.value].join(','),
  ];

  /// Tells [onEvent] `LongWaitDetected` for each queue of [connection]
  /// whose oldest job waits past its threshold, at most once per queue
  /// every [longWaitEvery] (wall clock). Called by [balance].
  void detectLongWaits(String connection, List<QueueLoad> loads) {
    for (final load in loads) {
      final wait = load.oldestWait;
      if (wait == null || wait <= load.targetWait) {
        continue;
      }
      final key = '$connection:${load.queue.value}';
      final now = DateTime.now();
      final last = _longWaits[key];
      if (last != null && now.difference(last) < longWaitEvery) {
        continue;
      }
      _longWaits[key] = now;
      onEvent?.call('LongWaitDetected', {
        'connection': connection,
        'queue': load.queue.value,
        'seconds': wait.inSeconds,
        'threshold': load.targetWait.inSeconds,
      });
    }
  }

  /// One evaluation of [plan]: reads its queues and applies [decide].
  Future<ScalingDecision> balance(SupervisorPlan plan) async {
    final name = plan.name.value;
    final queue = driver(plan.connection);
    final loads = <QueueLoad>[];
    for (final q in plan.queues) {
      final size = await queue.size(q.value);
      final wait = await queue.oldestWait(q.value);
      final (arrival, service) = await _rates(q.value);
      loads.add(
        QueueLoad(
          queue: q,
          size: size,
          oldestWait: wait,
          arrivalRate: arrival,
          serviceTime: service,
          targetWait: config.waitFor(queue.name, q.value),
        ),
      );
    }
    detectLongWaits(queue.name, loads);
    final previous = ScalingState(
      workers: _pools[name]?.where((w) => !w.stopping).length ?? 0,
      arrival: _states[name]?.arrival ?? const {},
      service: _states[name]?.service ?? const {},
      calm: _states[name]?.calm ?? 0,
    );
    final decision = decide(
      ScalingInput(
        plan: plan,
        queues: loads,
        alpha: config.ewmaAlpha,
        jobsPerProcess: config.jobsPerProcess,
      ),
      previous,
    );
    _states[name] = decision.state;
    final assignments = <String>[
      for (final MapEntry(key: q, value: n) in decision.perQueue.entries)
        for (var i = 0; i < n; i++) q,
      for (var i = 0; i < decision.shared; i++)
        [for (final q in plan.queues) q.value].join(','),
    ];
    if (!_stopping) {
      await _resize(plan, decision.total, assignments);
    }
    onEvent?.call('SupervisorLooped', {
      'plan': name,
      'reason': decision.reason,
      'before': previous.workers,
      'after': decision.total,
      'sizes': {for (final l in loads) l.queue.value: l.size},
    });
    return decision;
  }

  /// The jobs a second and the average run time of [queue] over the last
  /// minute, from the store; nulls when none is measured.
  Future<(double?, Duration?)> _rates(String queue) async {
    final store = horizonStore;
    if (store == null) {
      return (null, null);
    }
    try {
      final rates = await store.rates(queue);
      final avg = rates['avg_ms'] as num?;
      return (
        (rates['per_second'] as num?)?.toDouble(),
        avg == null ? null : Duration(microseconds: (avg * 1000).round()),
      );
    } on Object {
      return (null, null);
    }
  }

  /// [total] workers for [plan], given [assignments] (one queue list per
  /// worker, extra workers getting the last one); stops idle workers first.
  Future<void> _resize(
    SupervisorPlan plan,
    int total,
    List<String> assignments,
  ) async {
    final pool = _pools[plan.name.value]!;
    final live = [
      for (final w in pool)
        if (!w.stopping) w,
    ];
    if (live.length > total) {
      final idleFirst = [...live]
        ..sort((a, b) => (a.busy ? 1 : 0).compareTo(b.busy ? 1 : 0));
      for (final w in idleFirst.take(live.length - total)) {
        w.stopping = true;
        w._send(const Stop());
      }
    }
    final keep = [
      for (final w in pool)
        if (!w.stopping) w,
    ];
    String queuesFor(int i) => assignments.isEmpty
        ? _spreadAll(plan).first
        : assignments[i < assignments.length ? i : assignments.length - 1];
    for (var i = 0; i < keep.length; i++) {
      final queues = queuesFor(i);
      if (keep[i].queues != queues) {
        keep[i].queues = queues;
        keep[i]._send(Assign(queues));
      }
    }
    // Counted again on each spawn: a worker joins the pool before its
    // spawn is awaited, and a resize the caller did not wait for may run
    // beside this one.
    int running() => pool.where((w) => !w.stopping).length;
    while (running() < total && !_stopping) {
      await _spawn(plan, queuesFor(running()));
    }
  }

  Future<HorizonWorker> _spawn(SupervisorPlan plan, String queues) async {
    final planName = plan.name.value;
    final n = _next[planName] = (_next[planName] ?? 0) + 1;
    final worker = HorizonWorker._('horizon-$planName-$n', plan)
      ..queues = queues;
    _pools[planName]!.add(worker);
    // Spawned paused, so its exit is reported on the report port, after
    // its Exited if it sent one (one port keeps the order): an exit
    // without Exited first is a crash.
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        horizonWorkerMain,
        HorizonWorkerStart(
          factory: factory,
          name: worker.name,
          queues: queues,
          master: _reports.sendPort,
          heartbeat: config.heartbeat,
          coordinator: coordinator,
          connection: plan.connection,
          tries: plan.tries,
          backoffSeconds: plan.backoff == null
              ? null
              : [for (final b in plan.backoff!) b.inSeconds],
          timeout: plan.timeout,
          sleep: plan.sleep,
          maxJobs: plan.maxJobs,
          maxTime: plan.maxTime,
          idleTransactionTimeout: workerIdleTransactionTimeout,
        ),
        debugName: worker.name,
        paused: true,
      );
    } on Object {
      // Never started: a worker left in the pool without an isolate would
      // count as running for ever (a resize would never replace it).
      _pools[planName]?.remove(worker);
      rethrow;
    }
    isolate
      ..addOnExitListener(
        _reports.sendPort,
        response: <Object>['gone', worker.name],
      )
      ..addErrorListener(_reports.sendPort)
      ..resume(isolate.pauseCapability!);
    worker._isolate = isolate;
    logger.info('Horizon worker ${worker.name} started on [$queues].');
    return worker;
  }

  HorizonWorker? _worker(String name) {
    for (final pool in _pools.values) {
      for (final w in pool) {
        if (w.name == name) {
          return w;
        }
      }
    }
    return null;
  }

  void _onReport(Object? message) {
    switch (message) {
      case [final String name, final SendPort port]:
        // A worker's first message: where it takes commands.
        final w = _worker(name);
        w?._port = port;
        if (w != null && _isPaused(w)) {
          port.send(const Pause());
        }
      case ['gone', final String name]:
        final w = _worker(name);
        if (w != null) {
          _onGone(w, crashed: !w._saidExited);
        }
      case [final String? error, final String? stack]:
        // An uncaught error of a worker (addErrorListener); fatal ones end
        // it, and its exit follows.
        logger.error('Horizon worker error: $error\n$stack');
      case final Ready ready:
        _worker(ready.worker)
          ?..ready = true
          ..sessions = ready.sessions
          ..lastSeen = DateTime.now();
      case final Heartbeat beat:
        final w = _worker(beat.worker);
        if (w != null) {
          w
            ..last = beat
            ..sessions = beat.sessions
            ..lastSeen = DateTime.now();
          _checkGrace(w);
        }
      case final Exited exited:
        final w = _worker(exited.worker);
        w?._saidExited = true;
    }
  }

  /// How long, from its reservation, the job [w] runs may go on before its
  /// isolate is killed: the timeout the processor enforces for it (the
  /// plan's `timeout` when set, otherwise the job's own) plus `killGrace`,
  /// but never later than [_reclaimMargin] before the connection's
  /// `retry_after`: from then on the driver may give the job to another
  /// worker, which would run it beside this one. Null when [w] runs no job.
  ///
  /// The processor counts its timeout from the start of `handle`, this
  /// limit from the reservation: earlier by the job's `fromJson` and its
  /// middleware, a difference `killGrace` covers in the usual case. It is
  /// not the processor's timeout to the millisecond.
  Duration? _jobLimit(HorizonWorker w) {
    final beat = w.last;
    if (beat == null || beat.jobId == null || beat.jobReservedAtMs == null) {
      return null;
    }
    final timeout = switch (beat.jobTimeoutMs) {
      final int ms => Duration(milliseconds: ms),
      // A worker of an older release, which does not report it: the plan's
      // timeout, otherwise the default of `Job.timeout` (one minute, also
      // what a payload without `timeout` reads as).
      null => w.plan.timeout ?? const Duration(minutes: 1),
    };
    final limit = timeout + config.killGrace;
    final retryAfter = _retryAfter(w);
    if (retryAfter == null) {
      return limit;
    }
    final cap = retryAfter - _reclaimMargin;
    return limit < cap ? limit : cap;
  }

  /// The `retry_after` of [w]'s connection, for a driver that reserves.
  Duration? _retryAfter(HorizonWorker w) => switch (driver(w.plan.connection)) {
    final ReservingQueueDriver reserving => reserving.retryAfter,
    _ => null,
  };

  /// How long before `retry_after` the master kills a blocked worker, and
  /// after which it no longer reclaims its job: a heartbeat, at least a
  /// second. The job's time counts from its reservation, as the driver's
  /// `retry_after` does, so the margin is only a reserve for the two
  /// clocks and the report on its way.
  Duration get _reclaimMargin => config.heartbeat > const Duration(seconds: 1)
      ? config.heartbeat
      : const Duration(seconds: 1);

  /// A worker running a job is judged by that job's contract, not by its
  /// heartbeats: a handler doing synchronous work sends none, and is
  /// killed only past [_jobLimit] (reason `timeout`). Called on each
  /// heartbeat and by the master's own timer, so a worker that has gone
  /// silent is judged too.
  ///
  /// Returns whether [w] runs a job (then the lease does not apply).
  bool _checkGrace(HorizonWorker w) {
    final limit = _jobLimit(w);
    if (limit == null) {
      return false;
    }
    final started = DateTime.fromMillisecondsSinceEpoch(
      w.last!.jobReservedAtMs!,
    );
    if (w._isolate != null && DateTime.now().difference(started) > limit) {
      w._timedOut = true;
      _kill(w, 'timeout', reclaim: false);
    }
    return true;
  }

  /// Idle workers silent for three heartbeats (beyond the next one) are
  /// killed (reason `lease`) and the job they may have reserved without
  /// reporting it yet is reclaimed. Workers running a job are left to
  /// [_checkGrace].
  void _checkLeases() {
    final limit = config.heartbeat * 3;
    final now = DateTime.now();
    for (final pool in _pools.values) {
      for (final w in [...pool]) {
        if (w._isolate == null || !w.ready || w._exited.isCompleted) {
          continue;
        }
        if (_checkGrace(w)) {
          continue;
        }
        if (now.difference(w.lastSeen) > limit + config.heartbeat) {
          _kill(w, 'lease', reclaim: true);
        }
      }
    }
  }

  void _kill(HorizonWorker w, String reason, {required bool reclaim}) {
    final isolate = w._isolate;
    if (isolate == null) {
      return;
    }
    w._isolate = null;
    isolate.kill(priority: Isolate.immediate);
    final job = w.last;
    logger.warning('Horizon worker ${w.name} killed ($reason).');
    // The killed isolate's sockets stay open while the process lives, and a
    // transaction it left keeps its locks: end its sessions first, so the
    // reclaimed job does not wait on them.
    final ended = _endSessions(w).then((result) {
      onEvent?.call('WorkerKilled', {
        'worker': w.name,
        'reason': reason,
        'job': job?.jobUuid,
        'sessionsTerminated': result.$1,
        'failed': result.$2,
      });
    });
    w._sessionsEnded = ended;
    if (restartAfterKill case final why? when !_restartRequested) {
      _restartRequested = true;
      logger.error(
        why == 'sqlite_lock'
            ? 'Horizon killed ${w.name} on a SQLite file queue: its write lock '
                  'stays held until this process restarts.'
            : 'Horizon killed ${w.name}, and the database driver cannot end '
                  'its sessions: their locks stay held until this process '
                  'restarts.',
      );
      onEvent?.call('SupervisorLooped', {
        'plan': w.plan.name.value,
        'reason': why,
        'worker': w.name,
      });
      onRestartNeeded?.call();
    }
    if (reclaim) {
      w._reclaim = ended.then((_) => _reclaim(w));
    }
  }

  /// Ends the server sessions [w] last reported ([terminateSession]):
  /// (ended, failed).
  Future<(int, int)> _endSessions(HorizonWorker w) async {
    final terminate = terminateSession;
    final sessions = decodeSessions(w.sessions);
    w.sessions = '';
    if (terminate == null || sessions.isEmpty) {
      return (0, 0);
    }
    var ended = 0;
    var failed = 0;
    for (final MapEntry(key: connection, value: ids) in sessions.entries) {
      for (final id in ids) {
        try {
          if (await terminate(connection, id)) {
            ended++;
          }
        } on Object catch (e) {
          failed++;
          logger.error(
            'Could not end session $id ($connection) of ${w.name}: $e',
          );
        }
      }
    }
    if (ended > 0) {
      logger.info('Ended $ended database session(s) of ${w.name}.');
    }
    return (ended, failed);
  }

  /// Makes the job [w] held available again at once; true when it was
  /// still reserved.
  ///
  /// The driver reclaims by id: once `retry_after` (less [_reclaimMargin])
  /// has passed since the job was reserved, the driver may have given it to
  /// another worker already, whose reservation a reclaim would release
  /// (a third worker could then run it beside the second). Then the job is
  /// left to `retry_after`, and [HorizonWorker._leftToRetryAfter] is set.
  ///
  /// [pastWindow], when given, is the caller's own reading of
  /// [_pastReclaimWindow], used instead of reading it again.
  Future<bool> _reclaim(HorizonWorker w, {bool? pastWindow}) async {
    final job = w.last;
    final queue = job?.queue;
    final id = job?.jobId;
    final target = driver(w.plan.connection);
    if (queue == null || id == null || target is! ReclaimableQueueDriver) {
      return false;
    }
    if (pastWindow ?? _pastReclaimWindow(w)) {
      w._leftToRetryAfter = true;
      logger.info(
        'Job ${job?.jobUuid} of ${w.name} left to retry_after: it may '
        'have been given to another worker already.',
      );
      return false;
    }
    try {
      final done = await target.reclaim(queue, _key(id));
      logger.info(
        'Job ${job?.jobUuid} of ${w.name} '
        '${done ? 'reclaimed' : 'was no longer reserved'}.',
      );
      return done;
    } on Object catch (e) {
      w._reclaimFailed = true;
      logger.error('Could not reclaim job $id: $e');
      return false;
    }
  }

  /// Whether `retry_after` (less [_reclaimMargin]) has passed since [w]'s
  /// job was reserved: the driver may have given it to another worker, so
  /// the master no longer acts on it.
  bool _pastReclaimWindow(HorizonWorker w) {
    final started = w.last?.jobReservedAtMs;
    final retryAfter = _retryAfter(w);
    if (started == null || retryAfter == null) {
      return false;
    }
    final ran = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(started),
    );
    return ran >= retryAfter - _reclaimMargin;
  }

  /// The id as the driver stores it: a number for the database queue.
  static Object _key(String id) => int.tryParse(id) ?? id;

  /// Crashes per job uuid; a job reaching `quarantineAfter` is quarantined.
  final Map<String, int> _jobCrashes = {};

  /// A worker went down while running a job: the job is reclaimed (unless
  /// the lease did it) and counted; past `quarantineAfter` crashes it goes
  /// to `failed_jobs` and leaves the queue instead of crashing the next
  /// worker too.
  Future<void> _afterCrash(HorizonWorker w) async {
    final job = w.last;
    final uuid = job?.jobUuid;
    if (job == null || job.jobId == null || job.queue == null) {
      return;
    }
    await w._sessionsEnded;
    await (w._reclaim ?? _reclaim(w));
    if (uuid == null) {
      return;
    }
    final crashes = _jobCrashes[uuid] = (_jobCrashes[uuid] ?? 0) + 1;
    if (_jobCrashes.length > 1000) {
      _jobCrashes.remove(_jobCrashes.keys.first);
    }
    if (crashes >= config.quarantineAfter) {
      _jobCrashes.remove(uuid);
      await _quarantine(w.plan, job.queue!, job.jobId!, uuid, crashes);
    }
  }

  /// A worker killed for running past its job's timeout ([_checkGrace]).
  /// The processor never got back control to count the attempt, so the
  /// master does what a timeout does in `queue:work`:
  /// - the attempt counts once: attempts go up when a job is reserved, and
  ///   the reclaim keeps them;
  /// - the master decides, from the retry settings the worker reported and
  ///   nothing else, whether the job fails now, by the rule of Laravel's
  ///   timeout handler ([failsAfterTimeout]: tries used up or `retryUntil`
  ///   passed, the last allowed exception, `failOnTimeout`);
  /// - a job that fails is **marked** in [signals] before it is made
  ///   available again, and the worker that reserves it next fails it
  ///   without running it, with `TimeoutExceededException` ("NAME has
  ///   timed out."): `failed_jobs`, its `failed()` hook and `JobFailed`
  ///   run there, in a worker's application, never in the master (a job
  ///   that blocked its isolate could block the master's the same way);
  /// - any other job is made available again at once (no backoff: the
  ///   driver cannot release a reserved job with a delay from outside its
  ///   worker);
  /// - it is not a crash, and never counts towards `quarantineAfter`.
  ///
  /// Unlike Laravel, a failing job is recorded at its next reservation, not
  /// at the moment of the timeout; in between it looks available. Without
  /// [signals] or [failsAfterTimeout], or once `retry_after` has passed,
  /// nothing is marked: a job with no tries left then fails on its next
  /// pop with `MaxAttemptsExceededException`, and a `failOnTimeout` job
  /// with tries left runs again.
  ///
  /// `JobExceptionOccurred` is not dispatched for the killed attempt (the
  /// master runs no worker application): the master logs a warning and
  /// tells [onEvent] `JobTimedOut`, with its `fate`.
  Future<void> _afterTimeout(HorizonWorker w) async {
    // Never fails: it runs unawaited in the master's zone.
    try {
      final job = w.last!;
      await w._sessionsEnded;
      final limit = _jobLimit(w);
      // Judged once, for the mark and the reclaim alike: judged twice, the
      // window could pass in between, and a job marked to fail would be
      // left to retry_after unmarked. The reclaim margin (a heartbeat, at
      // least a second) covers the moment the mark takes.
      final past = _pastReclaimWindow(w);
      final marked = !past && await _markIfFails(w, limit);
      final reclaimed = await _reclaim(w, pastWindow: past);
      final store = signals;
      var willFail = marked;
      if (marked && !reclaimed && !w._reclaimFailed && store != null) {
        // No longer reserved: the job ended just before the kill (its row
        // is gone), so there is nothing of this attempt to fail. A reclaim
        // that failed keeps the mark: the job comes back after retry_after
        // and fails then.
        await HorizonSignals.unmarkTimedOut(store, job.jobUuid!);
        willFail = false;
      }
      final fate = willFail
          ? 'will fail on next reservation'
          : reclaimed
          ? 'made available again'
          : w._leftToRetryAfter
          ? 'left to retry_after'
          : w._reclaimFailed
          ? 'could not be made available again'
          : 'was no longer reserved';
      logger.warning(
        'Horizon job ${job.jobUuid ?? job.jobId} (${job.jobName}, attempt '
        '${job.attempt}) ran past its limit of ${limit?.inMilliseconds} ms '
        'on ${w.name}: the worker was killed, the attempt counted as timed '
        'out, and the job $fate.',
      );
      final data = <String, Object?>{
        'worker': w.name,
        'job': job.jobUuid,
        'name': job.jobName,
        'attempt': job.attempt,
        'limitSeconds': limit?.inSeconds,
        'reclaimed': reclaimed,
        'fate': fate,
        if (w._leftToRetryAfter) 'leftToRetryAfter': true,
        'at': DateTime.now().millisecondsSinceEpoch,
      };
      _timeouts.add(data);
      if (_timeouts.length > 20) {
        _timeouts.removeAt(0);
      }
      unawaited(_publishStatus());
      onEvent?.call('JobTimedOut', data);
    } on Object catch (error, stackTrace) {
      logger.error(
        'Horizon could not record the timeout of ${w.name}\'s job',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Marks [w]'s job to fail on its next reservation when it fails after
  /// this timeout ([failsAfterTimeout] on the retry settings [w] reported); true
  /// when marked. The caller does not ask once `retry_after` has passed (the
  /// job may be another worker's). Nothing is marked without a store, a rule or the job's retry
  /// settings, or when deciding or marking fails (the job is then made
  /// available again, as before).
  Future<bool> _markIfFails(HorizonWorker w, Duration? limit) async {
    final job = w.last;
    final store = signals;
    final decide = failsAfterTimeout;
    final uuid = job?.jobUuid;
    if (job == null ||
        store == null ||
        decide == null ||
        uuid == null ||
        job.jobMaxTries == null) {
      return false;
    }
    final attempt = job.attempt ?? 1;
    // The job's retry settings, as the worker reported them: the rule reads
    // nothing else of a payload, and the master never sees the job's data.
    final settings = JobPayload(
      uuid: uuid,
      jobName: job.jobName ?? '',
      displayName: job.jobName ?? '',
      data: const <String, Object?>{},
      maxTries: job.jobMaxTries!,
      maxExceptions: job.jobMaxExceptions,
      failOnTimeout: job.jobFailsOnTimeout ?? false,
      backoffSeconds: const <int>[],
      timeout: Duration.zero,
      pushedAt: 0,
      retryUntil: job.jobRetryUntil,
    );
    try {
      if (!await decide(settings, attempt, tries: w.plan.tries)) {
        return false;
      }
      final retryAfter = _retryAfter(w) ?? Duration.zero;
      await HorizonSignals.markTimedOut(
        store,
        uuid,
        attempt: attempt,
        limit: limit,
        // Past the next reservation even when the reclaim fails and the job
        // waits for retry_after.
        ttl: retryAfter * 2 > timedOutMarkTtl
            ? retryAfter * 2
            : timedOutMarkTtl,
      );
      return true;
    } on Object catch (e) {
      logger.error(
        'Could not decide or mark the timed-out job $uuid of ${w.name}: $e; '
        'it is made available again.',
      );
      return false;
    }
  }

  /// The least time a timed-out job's mark lives ([_markIfFails]): a job
  /// nobody reserves for that long is no longer failed by it, and runs
  /// again or fails by its tries.
  static const Duration timedOutMarkTtl = Duration(hours: 1);

  /// Moves job [id] of [queue] to `failed_jobs` with a
  /// [JobQuarantinedException] and removes it, through the queue driver and
  /// the failed job provider only.
  Future<void> _quarantine(
    SupervisorPlan plan,
    String queue,
    String id,
    String uuid,
    int crashes,
  ) async {
    final target = driver(plan.connection);
    final failed = failedJobs;
    if (target is! BrowsableQueueDriver || failed == null) {
      logger.error(
        'Job $uuid crashed $crashes workers; it cannot be quarantined on '
        'the [${target.name}] connection.',
      );
      return;
    }
    try {
      QueuedJobView? found;
      for (final view in await target.pending(queue, limit: 1000)) {
        if ('${view.id}' == id) {
          found = view;
          break;
        }
      }
      if (found == null) {
        return; // Already gone (finished elsewhere, or deleted).
      }
      final exception = JobQuarantinedException(uuid, crashes);
      await failed.log(
        connection: target.name,
        queue: queue,
        payload: found.payload,
        exception: '$exception\n${StackTrace.current}',
      );
      await target.delete(
        QueuedJob(
          id: found.id,
          queue: queue,
          payload: JobPayload.decode(found.payload),
          attempts: found.attempts,
          raw: found.payload,
        ),
      );
      logger.error('$exception; moved to failed_jobs.');
      onEvent?.call('JobQuarantined', {'job': uuid, 'crashes': crashes});
    } on Object catch (e) {
      logger.error('Could not quarantine job $uuid: $e');
    }
  }

  void _onGone(HorizonWorker w, {required bool crashed}) {
    if (!w._exited.isCompleted) {
      w._exited.complete();
    }
    _pools[w.plan.name.value]?.remove(w);
    if (crashed) {
      // A crashed isolate's sockets may stay open as a killed one's do.
      w._sessionsEnded ??= _endSessions(w);
    }
    if (crashed && w.last?.jobId != null) {
      unawaited(w._timedOut ? _afterTimeout(w) : _afterCrash(w));
    }
    if (w.recycling && !_stopping) {
      unawaited(_spawn(w.plan, w.queues));
      return;
    }
    if (_stopping || w.stopping) {
      return;
    }
    final plan = w.plan;
    if (!crashed) {
      // It ended on its own (max jobs, max time, a restart): replace it.
      unawaited(_spawn(plan, w.queues));
      return;
    }
    final now = DateTime.now();
    final recent = (_crashes[plan.name.value] ??= [])
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))
      ..add(now);
    final delay = _crashDelay(recent.length);
    logger.error(
      'Horizon worker ${w.name} crashed; starting another in '
      '${delay.inMilliseconds} ms.',
    );
    _timers.add(
      Timer(delay, () {
        if (!_stopping) {
          unawaited(_spawn(plan, w.queues));
        }
      }),
    );
  }

  /// Every worker stops taking jobs (`horizon:pause`).
  void pause() {
    _paused = true;
    for (final pool in _pools.values) {
      for (final w in pool) {
        w._send(const Pause());
      }
    }
  }

  /// Workers take jobs again (`horizon:continue`); a supervisor paused on
  /// its own stays paused.
  void resume() {
    _paused = false;
    for (final MapEntry(key: plan, value: pool) in _pools.entries) {
      if (_pausedPlans.contains(plan)) {
        continue;
      }
      for (final w in pool) {
        w._send(const Resume());
      }
    }
  }

  /// Supervisors paused on their own (`horizon:pause-supervisor`).
  final Set<String> _pausedPlans = {};

  /// The workers of supervisor [plan] stop taking jobs
  /// (`horizon:pause-supervisor`).
  void pauseSupervisor(String plan) {
    _pausedPlans.add(plan);
    for (final w in _pools[plan] ?? const <HorizonWorker>[]) {
      w._send(const Pause());
    }
  }

  /// Supervisor [plan] takes jobs again, unless all of Horizon is paused
  /// (`horizon:continue-supervisor`).
  void resumeSupervisor(String plan) {
    _pausedPlans.remove(plan);
    if (_paused) {
      return;
    }
    for (final w in _pools[plan] ?? const <HorizonWorker>[]) {
      w._send(const Resume());
    }
  }

  bool _isPaused(HorizonWorker w) =>
      _paused || _pausedPlans.contains(w.plan.name.value);

  /// Asks every worker to finish its job and exit, waits up to [timeout],
  /// then kills the rest.
  Future<void> stop({Duration timeout = const Duration(seconds: 30)}) async {
    _stopping = true;
    for (final t in _timers) {
      t.cancel();
    }
    await _publishStatus();
    final all = [for (final pool in _pools.values) ...pool];
    for (final w in all) {
      w
        ..stopping = true
        .._send(const Stop());
    }
    await Future.wait([for (final w in all) w.exited]).timeout(
      timeout,
      onTimeout: () {
        for (final w in all) {
          if (w._isolate case final isolate?) {
            w._isolate = null;
            isolate.kill(priority: Isolate.immediate);
            w._sessionsEnded ??= _endSessions(w);
          }
        }
        return const <void>[];
      },
    );
    await Future.wait([for (final w in all) ?w._sessionsEnded]);
    _reports.close();
  }
}

/// A job that brought its worker down `quarantineAfter` times in a row
/// (`HORIZON_QUARANTINE_AFTER`): recorded in `failed_jobs` with its payload,
/// so `queue:retry` can run it again once fixed, and removed from its queue.
final class JobQuarantinedException implements Exception {
  /// Job [uuid] crashed [crashes] workers.
  const JobQuarantinedException(this.uuid, this.crashes);

  /// The job's UUID.
  final String uuid;

  /// How many workers it brought down.
  final int crashes;

  @override
  String toString() =>
      'JobQuarantinedException: job $uuid brought down $crashes Horizon '
      'workers in a row';
}
