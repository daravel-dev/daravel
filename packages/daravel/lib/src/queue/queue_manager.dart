import 'dart:async';

import '../foundation/clock.dart';

import '../cache/cache.dart';
import '../database/database_manager.dart';
import '../events/events.dart';
import '../foundation/config.dart';
import '../foundation/config_validator.dart';
import '../foundation/container.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';
import '../logging/context.dart';
import '../logging/logger.dart';
import 'drivers.dart';
import 'job.dart';

/// `QUEUE_*` configuration (`config/queue.php` parity).
final class QueueConfig implements ConfigSection {
  const QueueConfig({
    this.defaultConnection = 'sync',
    this.defaultQueue = 'default',
    this.table = 'jobs',
    this.failedTable = 'failed_jobs',
    this.retryAfter = const Duration(seconds: 90),
    this.afterCommit = true,
    this.uniqueLockStore = 'process',
    this.signalStore,
  });

  factory QueueConfig.fromEnv(Env env) {
    final connection = env.string('QUEUE_CONNECTION', 'sync');
    return QueueConfig(
      defaultConnection: connection,
      defaultQueue: env.string('QUEUE_DEFAULT', 'default'),
      table: env.string('QUEUE_TABLE', 'jobs'),
      failedTable: env.string('QUEUE_FAILED_TABLE', 'failed_jobs'),
      retryAfter: env.duration(
        'QUEUE_RETRY_AFTER',
        const Duration(seconds: 90),
      ),
      afterCommit: env.boolean('QUEUE_AFTER_COMMIT', true),
      // `queue:work` processes release the locks that requests take: with
      // the database queue they must live where both see them.
      uniqueLockStore: env.string(
        'QUEUE_UNIQUE_LOCK_STORE',
        switch (connection) {
          'database' => 'database',
          'redis' => 'redis',
          _ => 'process',
        },
      ),
      signalStore: env.maybeString('QUEUE_SIGNAL_STORE'),
    );
  }

  /// Warns when the database queue keeps unique-job locks where separate
  /// `queue:work` processes cannot release them.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final queue = config.section<QueueConfig>();
    if (queue.defaultConnection != 'database' ||
        !const {'memory', 'process', 'file'}.contains(queue.uniqueLockStore)) {
      return const [];
    }
    return [
      ConfigIssue(
        ConfigIssueLevel.warning,
        'QUEUE_UNIQUE_LOCK_STORE=${queue.uniqueLockStore} with '
        'QUEUE_CONNECTION=database: a `dartisan queue:work` process cannot '
        'release unique-job locks taken by the server, so a unique job is not '
        'dispatched again until its lock expires. Use the database store '
        '(the default), or run the worker with `serve --embed-queue`.',
      ),
    ];
  }

  /// `sync` | `database` | `memory`.
  final String defaultConnection;
  final String defaultQueue;
  final String table;
  final String failedTable;
  final Duration retryAfter;

  /// Dispatches inside a transaction wait for the commit by default.
  final bool afterCommit;

  /// Cache store holding unique-job locks (`QUEUE_UNIQUE_LOCK_STORE`;
  /// `database` with the database queue, `redis` with the redis queue,
  /// `process` otherwise).
  final String uniqueLockStore;

  /// Cache store of `queue:restart` and `queue:pause` signals
  /// (`QUEUE_SIGNAL_STORE`): by default the `file` store with the database
  /// queue (one machine; `database` reaches every machine), [uniqueLockStore]
  /// otherwise.
  final String? signalStore;

  @override
  String get key => 'queue';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'default': defaultConnection,
    'queue': defaultQueue,
    'after_commit': afterCommit,
    'connections': {
      'sync': {'driver': 'sync'},
      'memory': {'driver': 'memory'},
      'database': {
        'driver': 'database',
        'table': table,
        'retry_after': retryAfter.inSeconds,
      },
    },
    'failed': {'table': failedTable},
  };
}

/// Recorded pushes while [QueueManager.fake] is active.
final class QueueFake {
  final List<({Job job, String queue, String connection, Duration? delay})>
  pushed = [];

  List<J> pushedJobs<J extends Job>([bool Function(J job)? where]) => [
    for (final entry in pushed)
      if (entry.job is J && (where == null || where(entry.job as J)))
        entry.job as J,
  ];

  void assertPushed<J extends Job>([bool Function(J job)? where]) {
    if (pushedJobs<J>(where).isEmpty) {
      throw StateError('Expected job [$J] to be pushed; it was not.');
    }
  }

  void assertPushedOn<J extends Job>(String queue) {
    if (!pushed.any((e) => e.job is J && e.queue == queue)) {
      throw StateError('Expected job [$J] on queue [$queue]; it was not.');
    }
  }

  void assertNotPushed<J extends Job>() {
    if (pushedJobs<J>().isNotEmpty) {
      throw StateError('Expected job [$J] not to be pushed; it was.');
    }
  }

  void assertNothingPushed() {
    if (pushed.isNotEmpty) {
      throw StateError(
        'Expected no jobs; got ${pushed.map((e) => e.job.jobName).join(', ')}.',
      );
    }
  }

  int pushedTimes<J extends Job>() => pushedJobs<J>().length;
}

/// Fluent dispatch (`dispatch($job)->onQueue('x')->delay(...)`). Awaiting it
/// performs the push and yields the driver job id (`null` when a unique
/// job was skipped).
final class PendingDispatch implements Future<Object?> {
  PendingDispatch(this._manager, this.job);

  final QueueManager _manager;
  final Job job;
  String? _queue;
  String? _connection;
  Duration? _delay;
  bool? _afterCommit;
  Future<Object?>? _future;

  PendingDispatch onQueue(String queue) => this.._queue = queue;

  PendingDispatch onConnection(String connection) =>
      this.._connection = connection;

  PendingDispatch delay(Duration delay) => this.._delay = delay;

  PendingDispatch afterCommit() => this.._afterCommit = true;

  PendingDispatch beforeCommit() => this.._afterCommit = false;

  Future<Object?> get _run => _future ??= _manager.push(
    job,
    queue: _queue,
    connection: _connection,
    delay: _delay,
    afterCommit: _afterCommit,
  );

  @override
  Stream<Object?> asStream() => _run.asStream();

  @override
  Future<Object?> catchError(Function onError, {bool Function(Object)? test}) =>
      _run.catchError(onError, test: test);

  @override
  Future<R> then<R>(
    FutureOr<R> Function(Object? value) onValue, {
    Function? onError,
  }) => _run.then(onValue, onError: onError);

  @override
  Future<Object?> timeout(
    Duration timeLimit, {
    FutureOr<Object?> Function()? onTimeout,
  }) => _run.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<Object?> whenComplete(FutureOr<void> Function() action) =>
      _run.whenComplete(action);
}

/// Outcome of one processing attempt.
enum JobOutcome { processed, released, deleted, failed }

/// Runs one reserved job through its middleware with timeout, retry and
/// failure bookkeeping (shared by the worker and the sync driver).
final class JobProcessor {
  JobProcessor({
    required this.registry,
    required this.events,
    required this.failedJobs,
    required this.container,
    this.logger,
    this.uniqueLockRelease,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  final JobRegistry registry;
  final EventDispatcher events;
  final FailedJobProvider failedJobs;
  final Container container;
  final Logger? logger;

  /// Releases the unique-job lock named by the payload.
  final Future<void> Function(String key)? uniqueLockRelease;
  final DateTime Function() _clock;

  /// Processes [queued] from [driver]. [tries]/[backoff] override the job's
  /// own values when the worker was started with `--tries/--backoff`.
  Future<JobOutcome> process(
    QueueDriver driver,
    QueuedJob queued, {
    int? tries,
    List<Duration>? backoff,
    Duration? timeout,
  }) async {
    final payload = queued.payload;
    final Job job;
    try {
      job = registry.make(payload.jobName, payload.data);
    } on UnknownJobException catch (error, stackTrace) {
      await _fail(driver, queued, error, stackTrace, job: null);
      return .failed;
    }
    final maxTries = (tries ?? payload.maxTries);
    final ctx = JobContext(
      id: queued.id,
      attempt: queued.attempts,
      queue: queued.queue,
      connection: driver.name,
      payload: payload.data,
      maxTries: maxTries == 0 ? null : maxTries,
    );
    await events.dispatch(
      JobProcessing(
        connection: driver.name,
        queue: queued.queue,
        jobName: payload.jobName,
        jobId: queued.id,
        attempt: queued.attempts,
      ),
    );
    final stopwatch = Stopwatch()..start();
    Object? error;
    StackTrace? trace;
    var timedOut = false;
    try {
      await container.runScoped<void>('job', (_) async {
        Context.current.hydrate(payload.context);
        await _runWithMiddleware(ctx, job, () async {
          try {
            await job.handle(ctx).timeout(timeout ?? payload.timeout);
          } on TimeoutException {
            ctx.cancelled = true;
            timedOut = true;
            rethrow;
          }
        });
      });
    } catch (e, s) {
      error = e;
      trace = s;
    }
    final failure = ctx.failure;
    if (failure != null && error == null) {
      error = failure;
      trace = StackTrace.current;
    }
    if (error == null) {
      if (ctx.deleted) {
        await _finish(driver, queued, payload);
        return .deleted;
      }
      if (ctx.released) {
        await driver.release(queued, ctx.releaseDelay ?? Duration.zero);
        return .released;
      }
      await _finish(driver, queued, payload);
      await events.dispatch(
        JobProcessed(
          connection: driver.name,
          queue: queued.queue,
          jobName: payload.jobName,
          jobId: queued.id,
          duration: stopwatch.elapsed,
        ),
      );
      return .processed;
    }
    final exhausted =
        _exhausted(payload, queued.attempts, maxTries) ||
        failure != null ||
        (timedOut && payload.failOnTimeout);
    await events.dispatch(
      JobExceptionOccurred(
        connection: driver.name,
        queue: queued.queue,
        jobName: payload.jobName,
        jobId: queued.id,
        error: error,
        willRetry: !exhausted,
      ),
    );
    if (exhausted) {
      await _fail(driver, queued, error, trace ?? StackTrace.current, job: job);
      return .failed;
    }
    final delay = _backoff(
      backoff ?? [for (final s in payload.backoffSeconds) Duration(seconds: s)],
      queued.attempts,
    );
    logger?.warning(
      'Job ${payload.displayName} attempt ${queued.attempts} failed; '
      'retrying in ${delay.inSeconds}s: $error',
    );
    await driver.release(queued, delay);
    return .released;
  }

  bool _exhausted(JobPayload payload, int attempts, int maxTries) {
    final retryUntil = payload.retryUntil;
    if (retryUntil != null) {
      return _clock().millisecondsSinceEpoch ~/ 1000 >= retryUntil;
    }
    return maxTries > 0 && attempts >= maxTries;
  }

  static Duration _backoff(List<Duration> backoff, int attempt) {
    if (backoff.isEmpty) {
      return Duration.zero;
    }
    final index = attempt - 1;
    return index < backoff.length ? backoff[index] : backoff.last;
  }

  Future<void> _runWithMiddleware(JobContext ctx, Job job, JobNext core) {
    JobNext next = core;
    for (final middleware in job.middleware.reversed) {
      final downstream = next;
      next = () => middleware.handle(ctx, job, downstream);
    }
    return next();
  }

  Future<void> _finish(
    QueueDriver driver,
    QueuedJob queued,
    JobPayload payload,
  ) async {
    await driver.delete(queued);
    final unique = payload.uniqueKey;
    if (unique != null) {
      await uniqueLockRelease?.call(unique);
    }
  }

  Future<void> _fail(
    QueueDriver driver,
    QueuedJob queued,
    Object error,
    StackTrace stackTrace, {
    required Job? job,
  }) async {
    await _finish(driver, queued, queued.payload);
    await failedJobs.log(
      connection: driver.name,
      queue: queued.queue,
      payload: queued.raw,
      exception: '$error\n$stackTrace',
    );
    logger?.error(
      'Job ${queued.payload.displayName} failed',
      error: error,
      stackTrace: stackTrace,
      context: <String, Object?>{'job_id': queued.id, 'queue': queued.queue},
    );
    try {
      await job?.failed(error, stackTrace);
    } catch (hookError, hookTrace) {
      logger?.error(
        'failed() hook of ${queued.payload.displayName} threw',
        error: hookError,
        stackTrace: hookTrace,
      );
    }
    await events.dispatch(
      JobFailed(
        connection: driver.name,
        queue: queued.queue,
        jobName: queued.payload.jobName,
        jobId: queued.id,
        error: error,
      ),
    );
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Connections, dispatching, unique jobs and faking (Laravel `QueueManager`
/// + `Bus::dispatch`).
final class QueueManager {
  QueueManager({
    required this.config,
    required this.registry,
    required this.events,
    required this.container,
    required this.processor,
    this.database,
    this.lockStore,
    this._signalStore,
    this.logger,
  });

  final QueueConfig config;
  final JobRegistry registry;
  final EventDispatcher events;
  final Container container;
  final JobProcessor processor;
  final DatabaseManager? database;

  /// Store for unique-job locks (`ShouldBeUnique`).
  final CacheRepository? lockStore;

  /// Where [restart] and [pause] signals live (defaults to [lockStore]):
  /// the commands run in a process of their own, so it must be a store the
  /// workers read too.
  CacheRepository? get signalStore => _signalStore ?? lockStore;
  final CacheRepository? _signalStore;
  final Logger? logger;

  final Map<String, QueueDriver Function()> _factories = {};
  final Map<String, QueueDriver> _connections = <String, QueueDriver>{};
  QueueFake? _fake;

  /// Registers a connection factory.
  void extend(String name, QueueDriver Function() factory) =>
      _factories[name] = factory;

  Iterable<String> get connectionNames => _factories.keys;

  /// The connection named [name] (default: `QUEUE_CONNECTION`).
  QueueDriver connection([String? name]) {
    final resolved = name ?? config.defaultConnection;
    final existing = _connections[resolved];
    if (existing != null) {
      return existing;
    }
    final factory = _factories[resolved];
    if (factory == null) {
      throw ConfigException(
        'Queue connection [$resolved] is not defined (available: '
        '${_factories.keys.join(', ')}).',
      );
    }
    final driver = factory();
    if (driver is SyncQueue) {
      driver.processor = (payload, queue) =>
          _processSync(driver, payload, queue);
    }
    return _connections[resolved] = driver;
  }

  /// Fluent dispatch; await the result to push.
  PendingDispatch dispatch(Job job) => PendingDispatch(this, job);

  /// Pushes [job]; returns the driver id or `null` when a unique job with
  /// the same id is already pending.
  Future<Object?> push(
    Job job, {
    String? queue,
    String? connection,
    Duration? delay,
    bool? afterCommit,
  }) async {
    final fake = _fake;
    final targetQueue = queue ?? job.queue ?? config.defaultQueue;
    final targetConnection =
        connection ?? job.connection ?? config.defaultConnection;
    if (fake != null) {
      fake.pushed.add((
        job: job,
        queue: targetQueue,
        connection: targetConnection,
        delay: delay,
      ));
      return fake.pushed.length;
    }
    final db = database;
    final deferToCommit =
        (afterCommit ?? config.afterCommit) && db != null && db.inTransaction;
    if (deferToCommit) {
      await db.afterCommit(
        () => _pushNow(job, targetQueue, targetConnection, delay),
      );
      return null;
    }
    return _pushNow(job, targetQueue, targetConnection, delay);
  }

  Future<Object?> _pushNow(
    Job job,
    String queue,
    String connection,
    Duration? delay,
  ) async {
    String? uniqueKey;
    final uniqueId = job.uniqueId;
    if (uniqueId != null) {
      final store = lockStore;
      if (store == null) {
        throw const ConfigException('Unique jobs need a cache lock store.');
      }
      uniqueKey = 'unique:${job.jobName}:$uniqueId';
      final ttl = job.uniqueFor == Duration.zero
          ? const Duration(days: 365)
          : job.uniqueFor;
      if (!await store.lock(uniqueKey, ttl: ttl).acquire()) {
        logger?.debug(
          'Unique job ${job.displayName} [$uniqueId] already pending; skipped.',
        );
        return null;
      }
    }
    final payload = JobPayload.forJob(job, uniqueKey: uniqueKey);
    return this
        .connection(connection)
        .push(payload, queue: queue, delay: delay);
  }

  /// Pushes after [delay].
  Future<Object?> later(
    Duration delay,
    Job job, {
    String? queue,
    String? connection,
  }) => push(job, queue: queue, connection: connection, delay: delay);

  /// Pushes several jobs.
  Future<List<Object?>> bulk(
    Iterable<Job> jobs, {
    String? queue,
    String? connection,
  }) async => [
    for (final job in jobs)
      await push(job, queue: queue, connection: connection),
  ];

  /// Releases a unique-job lock (called by the processor).
  Future<void> releaseUniqueLock(String key) async {
    await lockStore?.lock(key).forceRelease();
  }

  Future<void> _processSync(
    SyncQueue driver,
    JobPayload payload,
    String queue,
  ) async {
    final queued = QueuedJob(
      id: payload.uuid,
      queue: queue,
      payload: payload,
      attempts: 1,
      raw: payload.encode(),
    );
    final outcome = await processor.process(driver, queued, tries: 1);
    if (outcome == .released) {
      logger?.warning(
        'Sync job ${payload.displayName} asked to be released; sync jobs cannot be retried.',
      );
    }
  }

  /// Records pushes instead of sending them (tests).
  QueueFake fake() => _fake = QueueFake();

  void restore() => _fake = null;

  /// Requests every running worker to stop after its current job.
  Future<void> restart() async {
    await signalStore?.store.put(
      'daravel:queue:restart',
      DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// Timestamp of the last [restart] request (epoch ms) or `null`.
  Future<int?> restartRequestedAt() async =>
      (await signalStore?.store.get('daravel:queue:restart')) as int?;

  static String _pauseKey(String connection, String queue) =>
      'daravel:queue:paused:$connection:$queue';

  /// Stops every worker from taking jobs off [queue] until [resume]
  /// (`queue:pause`); running jobs finish. Shared through the cache store,
  /// like [restart].
  Future<void> pause(String queue, {String? connection}) async => signalStore
      ?.store
      .forever(_pauseKey(_connectionName(connection), queue), true);

  /// Lets workers take jobs off [queue] again (`queue:continue`).
  Future<void> resume(String queue, {String? connection}) async {
    await signalStore?.store.forget(
      _pauseKey(_connectionName(connection), queue),
    );
  }

  /// Whether [queue] on [connection] is paused by [pause].
  Future<bool> isPaused(String queue, {String? connection}) async =>
      await signalStore?.store.get(
        _pauseKey(_connectionName(connection), queue),
      ) ==
      true;

  String _connectionName(String? connection) =>
      connection ?? config.defaultConnection;
}

/// `queue:work` options.
final class WorkerOptions {
  const WorkerOptions({
    this.connection,
    this.queues = const <String>['default'],
    this.tries,
    this.backoff,
    this.timeout,
    this.sleep = const Duration(seconds: 3),
    this.maxJobs,
    this.maxTime,
    this.stopWhenEmpty = false,
  });

  final String? connection;

  /// Queues polled in priority order.
  final List<String> queues;

  /// Overrides the job's `tries` (`null` = use the job's own value).
  final int? tries;
  final List<Duration>? backoff;
  final Duration? timeout;
  final Duration sleep;
  final int? maxJobs;
  final Duration? maxTime;
  final bool stopWhenEmpty;
}

/// Polls queues and processes jobs (`dartisan queue:work`).
final class QueueWorker {
  QueueWorker(this.manager, {this._logger});

  final QueueManager manager;
  final Logger? _logger;
  bool _stop = false;
  bool _paused = false;
  int processed = 0;

  /// Stops after the current job.
  void stop() {
    _stop = true;
    final idle = _idle;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }

  /// Completed by [stop] while the worker waits for work.
  Completer<void>? _idle;

  /// Stops taking new jobs (the current one finishes) until [resume]; for
  /// embedding supervisors. [QueueManager.pause] pauses a queue for every
  /// worker instead.
  void pause() => _paused = true;

  /// Takes jobs again after [pause].
  void resume() => _paused = false;

  /// Whether [pause] is in effect.
  bool get paused => _paused;

  /// Runs until stopped, [WorkerOptions.maxJobs]/[WorkerOptions.maxTime]
  /// are reached, or the queue is empty with [WorkerOptions.stopWhenEmpty].
  /// Returns the exit code (0, or 1 when stopped by `queue:restart`).
  Future<int> run(WorkerOptions options) async {
    _stop = false;
    final started = DateTime.now().toUtc();
    final restartMark = await manager.restartRequestedAt();
    final driver = manager.connection(options.connection);
    _logger?.info(
      'Processing jobs from [${options.queues.join(', ')}] on connection '
      '[${driver.name}].',
    );
    try {
      while (!_stop) {
        final ran = await runNextJob(driver, options);
        if (ran) {
          processed++;
        }
        final maxJobs = options.maxJobs;
        if (maxJobs != null && processed >= maxJobs) {
          break;
        }
        final maxTime = options.maxTime;
        if (maxTime != null &&
            DateTime.now().toUtc().difference(started) >= maxTime) {
          break;
        }
        final restart = await manager.restartRequestedAt();
        if (restart != null && restart != restartMark) {
          _logger?.info('Restart requested; worker stopping.');
          return 1;
        }
        if (!ran) {
          if (options.stopWhenEmpty) {
            break;
          }
          await _waitForWork(driver, options);
        }
      }
    } finally {
      if (driver is WakeableQueueDriver) {
        await driver.stopWaiting();
      }
    }
    return 0;
  }

  /// Up to [WorkerOptions.sleep]: less when the driver wakes the worker on
  /// a push ([WakeableQueueDriver]) or [stop] is called.
  Future<void> _waitForWork(QueueDriver driver, WorkerOptions options) async {
    final idle = _idle = Completer<void>();
    final wait = driver is WakeableQueueDriver
        ? driver.waitForWork(options.queues, options.sleep)
        : Future<void>.delayed(options.sleep);
    await Future.any([wait, idle.future]);
    _idle = null;
  }

  /// Processes at most one job; returns whether one was found. Paused
  /// workers and paused queues ([QueueManager.pause]) are skipped.
  Future<bool> runNextJob(QueueDriver driver, WorkerOptions options) async {
    if (_paused) {
      return false;
    }
    for (final queue in options.queues) {
      if (await manager.isPaused(queue, connection: options.connection)) {
        continue;
      }
      final job = await driver.pop(queue);
      if (job == null) {
        continue;
      }
      await manager.processor.process(
        driver,
        job,
        tries: options.tries,
        backoff: options.backoff,
        timeout: options.timeout,
      );
      return true;
    }
    return false;
  }
}
