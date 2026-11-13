import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../foundation/clock.dart';

import '../cache/cache.dart';
import '../database/database_manager.dart';
import '../database/orm/model.dart';
import '../events/events.dart';
import '../foundation/config.dart';
import '../foundation/config_validator.dart';
import '../foundation/container.dart';
import '../foundation/retryable_job.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';
import '../logging/context.dart';
import '../logging/logger.dart';
import 'drivers.dart';
import 'job.dart';

/// `QUEUE_*` configuration (`config/queue.php` parity).
final class QueueConfig implements ConfigSection {
  /// Queue settings; usually from `.env` ([QueueConfig.fromEnv]).
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

  /// The settings in `QUEUE_*`.
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

  /// The queue used when a job names none (`default`).
  final String defaultQueue;

  /// The jobs table (`jobs`).
  final String table;

  /// The failed jobs table (`failed_jobs`).
  final String failedTable;

  /// How long a reserved job may run before another worker takes it
  /// (`QUEUE_RETRY_AFTER`).
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
  /// Every job pushed while faked, with where it went.
  final List<({Job job, String queue, String connection, Duration? delay})>
  pushed = [];

  /// The pushed jobs of type [J], matching [where] when given.
  List<J> pushedJobs<J extends Job>([bool Function(J job)? where]) => [
    for (final entry in pushed)
      if (entry.job is J && (where == null || where(entry.job as J)))
        entry.job as J,
  ];

  /// Fails unless a job of type [J] (matching [where]) was pushed.
  void assertPushed<J extends Job>([bool Function(J job)? where]) {
    if (pushedJobs<J>(where).isEmpty) {
      throw StateError('Expected job [$J] to be pushed; it was not.');
    }
  }

  /// Fails unless a job of type [J] was pushed onto [queue].
  void assertPushedOn<J extends Job>(String queue) {
    if (!pushed.any((e) => e.job is J && e.queue == queue)) {
      throw StateError('Expected job [$J] on queue [$queue]; it was not.');
    }
  }

  /// Fails if a job of type [J] was pushed.
  void assertNotPushed<J extends Job>() {
    if (pushedJobs<J>().isNotEmpty) {
      throw StateError('Expected job [$J] not to be pushed; it was.');
    }
  }

  /// Fails if any job was pushed.
  void assertNothingPushed() {
    if (pushed.isNotEmpty) {
      throw StateError(
        'Expected no jobs; got ${pushed.map((e) => e.job.jobName).join(', ')}.',
      );
    }
  }

  /// How many jobs of type [J] were pushed.
  int pushedTimes<J extends Job>() => pushedJobs<J>().length;
}

/// Fluent dispatch (`dispatch($job)->onQueue('x')->delay(...)`). The job is
/// pushed in a microtask, after the setters chained on the dispatch, whether
/// or not it is awaited (as Laravel pushes from `PendingDispatch`'s
/// destructor); awaiting it yields the driver job id (`null` when a unique
/// job was skipped) or the push's error. A failed push nobody awaits is
/// logged.
final class PendingDispatch implements Future<Object?> {
  /// A dispatch of [job], pushed in a microtask.
  PendingDispatch(this._manager, this.job) {
    scheduleMicrotask(_start);
  }

  final QueueManager _manager;

  /// The job dispatched.
  final Job job;
  String? _queue;
  String? _connection;
  Duration? _delay;
  bool? _afterCommit;
  Future<Object?>? _future;
  bool _observed = false;

  PendingDispatch _set(void Function() change) {
    if (_future != null) {
      throw StateError(
        'The dispatch of ${job.displayName} was already pushed; chain '
        'onQueue/delay/... directly on Queue.dispatch(...).',
      );
    }
    change();
    return this;
  }

  /// Pushes onto [queue].
  PendingDispatch onQueue(String queue) => _set(() => _queue = queue);

  /// Pushes onto the connection [connection].
  PendingDispatch onConnection(String connection) =>
      _set(() => _connection = connection);

  /// Runs the job after [delay].
  PendingDispatch delay(Duration delay) => _set(() => _delay = delay);

  /// Laravel's `withoutDelay()`: at once, whatever delay the job declares.
  PendingDispatch withoutDelay() => _set(() => _delay = Duration.zero);

  /// Pushes only after the current transaction commits.
  PendingDispatch afterCommit() => _set(() => _afterCommit = true);

  /// Pushes at once, even inside a transaction.
  PendingDispatch beforeCommit() => _set(() => _afterCommit = false);

  Future<Object?> _push() => _future ??= _manager.push(
    job,
    queue: _queue,
    connection: _connection,
    delay: _delay,
    afterCommit: _afterCommit,
  );

  /// The microtask: pushes unless an `await` already did.
  void _start() {
    if (_future != null) {
      return;
    }
    unawaited(
      _push().then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!_observed) {
            _manager.logger?.error(
              'Dispatching ${job.displayName} failed',
              error: error,
              stackTrace: stackTrace,
            );
          }
        },
      ),
    );
  }

  Future<Object?> get _run {
    _observed = true;
    return _push();
  }

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
enum JobOutcome {
  /// The job finished and was removed.
  processed,

  /// The job was put back on the queue for a later attempt.
  released,

  /// The job asked to be removed without failing.
  deleted,

  /// The job failed for good and went to `failed_jobs`.
  failed,
}

/// Runs one reserved job through its middleware with timeout, retry and
/// failure bookkeeping (shared by the worker and the sync driver).
final class JobProcessor {
  /// A processor running jobs from [registry] in [container], reporting to
  /// [events] and recording failures in [failedJobs].
  JobProcessor({
    required this.registry,
    required this.events,
    required this.failedJobs,
    required this.container,
    this.logger,
    this.uniqueLockRelease,
    this.debounceStore,
    this.exceptionStore,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  /// Rebuilds jobs from their payloads.
  final JobRegistry registry;

  /// Receives the job lifecycle events.
  final EventDispatcher events;

  /// Records failed jobs.
  final FailedJobProvider failedJobs;

  /// The container jobs run in.
  final Container container;

  /// Logs job failures.
  final Logger? logger;

  /// Releases the unique-job lock named by the payload.
  final Future<void> Function(String key)? uniqueLockRelease;

  /// Holds the owner of each debounced job.
  final CacheRepository? Function()? debounceStore;

  /// Counts the exceptions of jobs with [Job.maxExceptions]
  /// (`job-exceptions:<uuid>`, as Laravel's worker does in its cache).
  final CacheRepository? Function()? exceptionStore;

  /// The `retry_after` warnings already given, per connection and job.
  final Set<String> _retryAfterWarned = <String>{};

  /// The cache key debouncing [job] (Laravel's, ADR-041).
  static String debounceKey(Job job) =>
      QueueLockKeys.debounce(job.displayName, job.debounceId);

  /// The key the previous release debounced [job] under (ADR-041).
  static String legacyDebounceKey(Job job) =>
      QueueLockKeys.legacyDebounce(job.jobName, job.debounceId);
  final DateTime Function() _clock;

  /// How many jobs were released after a timeout with their handler still
  /// running (Dart cannot cancel it): the worker stops when it grows, so
  /// the process is restarted and attempt 1 does not run next to attempt 2.
  int timedOutAndReleased = 0;

  /// Processes [queued] from [driver]. [tries]/[backoff] override the job's
  /// own values when the worker was started with `--tries/--backoff`.
  Future<JobOutcome> process(
    QueueDriver driver,
    QueuedJob queued, {
    int? tries,
    List<Duration>? backoff,
    Duration? timeout,
    Duration? extendEvery,
    void Function(QueuedJob job, DateTime until)? onReservationExtended,
  }) async {
    final payload = queued.payload;
    final Job job;
    try {
      job = registry.make(payload.jobName, payload.data);
    } on Object catch (error, stackTrace) {
      // An unknown job name, or a fromJson that throws on this payload (one
      // written by another release): retrying cannot help, and letting it
      // escape ended the worker with the row re-reserved for the next one.
      await _fail(driver, queued, error, stackTrace, job: null);
      return .failed;
    }
    final owner = payload.debounceOwner;
    final debounce = owner == null ? null : debounceStore?.call();
    final debounced = debounceKey(job);
    if (debounce != null) {
      // A newer dispatch took over. No owner at all is run: the cache may
      // have lost it, and a lost update is worse than an extra run.
      // Laravel's key, else the previous release's (a dispatch made by an
      // instance of it during a deploy; ADR-041).
      final current =
          await debounce.get<String>(debounced) ??
          (QueueLockKeys.legacyKeys
              ? await debounce.get<String>(legacyDebounceKey(job))
              : null);
      if (current != null && current != owner) {
        await _finish(driver, queued, payload);
        return .deleted;
      }
      await debounce.forget('$debounced:first_dispatched_at');
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
    await _announce(
      JobProcessing(
        connection: driver.name,
        queue: queued.queue,
        jobName: payload.jobName,
        jobId: queued.id,
        attempt: queued.attempts,
        uuid: payload.uuid,
        displayName: payload.displayName,
        tags: payload.tags,
        pushedAt: payload.pushedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(
                payload.pushedAt * 1000,
                isUtc: true,
              )
            : null,
        context: payload.context,
        timeout: timeout ?? payload.timeout,
      ),
    );
    if (_alreadyExceeded(payload, queued.attempts, maxTries)) {
      // Laravel's markJobAsFailedIfAlreadyExceedsMaxAttempts: a job
      // reserved again after its last try (released by middleware such as
      // WithoutOverlapping, or abandoned past its timeout) fails without
      // running, instead of being released for ever.
      if (debounce != null && await debounce.get<String>(debounced) == owner) {
        await debounce.forget(debounced);
      }
      await _fail(
        driver,
        queued,
        MaxAttemptsExceededException(
          payload.displayName,
          attempts: queued.attempts,
        ),
        StackTrace.current,
        job: job,
      );
      return .failed;
    }
    final limit = timeout ?? payload.timeout;
    _warnRetryAfter(driver, payload.displayName, limit);
    final heartbeat = _heartbeat(
      driver,
      queued,
      every: extendEvery,
      onExtended: onReservationExtended,
    );
    final stopwatch = Stopwatch()..start();
    Object? error;
    StackTrace? trace;
    var timedOut = false;
    // The first asynchronous error the handler leaves uncaught (a
    // fire-and-forget future) while it runs. It fails the attempt once the
    // handler has returned, never before: failing earlier released the job
    // and started attempt 2 beside attempt 1 in this very worker.
    (Object, StackTrace)? stray;
    var running = true;
    try {
      await ctx.cancellation.run(
        // Whether a failure is retried: not on `sync`, which runs the job
        // inline in its caller (a broadcast the coordinator sheds there is
        // dropped and told, as in a request, not raised for a retry).
        () => runZoned(
          zoneValues: {retryableJobKey: driver is! SyncQueue},
          () => container.runScoped<void>(
            'job',
            (_) async {
              Context.current.hydrate(payload.context);
              await _runWithMiddleware(ctx, job, () async {
                // Only this timer is the job's timeout: a TimeoutException
                // of the handler's own (an HTTP client's) is an ordinary
                // failure, retried with backoff, as it was not before.
                await job
                    .handle(ctx)
                    .timeout(
                      limit,
                      onTimeout: () {
                        ctx.cancelled = true;
                        timedOut = true;
                        throw TimeoutExceededException(
                          payload.displayName,
                          limit,
                        );
                      },
                    );
              });
            },
            onUncaughtError: (e, s) {
              if (running && stray == null) {
                stray = (e, s);
              } else {
                logger?.error(
                  'Uncaught asynchronous error in job ${payload.displayName}',
                  error: e,
                  stackTrace: s,
                  context: <String, Object?>{'job_id': queued.id},
                );
              }
            },
          ),
        ),
      );
    } catch (e, s) {
      error = e;
      trace = s;
    } finally {
      running = false;
      heartbeat?.cancel();
    }
    final strayError = stray;
    if (error == null && strayError != null) {
      (error, trace) = strayError;
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
      if (debounce != null && await debounce.get<String>(debounced) == owner) {
        await debounce.forget(debounced);
      }
      await _announce(
        JobProcessed(
          connection: driver.name,
          queue: queued.queue,
          jobName: payload.jobName,
          jobId: queued.id,
          duration: stopwatch.elapsed,
          uuid: payload.uuid,
          attempt: queued.attempts,
        ),
      );
      return .processed;
    }
    // `CallQueuedHandler::handleModelNotFound`: another attempt cannot bring
    // the row back.
    final missingModel = error is ModelNotFoundException;
    if (missingModel && job.deleteWhenMissingModels) {
      await _finish(driver, queued, payload);
      return .deleted;
    }
    // A timeout counts towards maxExceptions too, as in Laravel's timeout
    // handler (failsAfterTimeout, for a worker killed past it, is this rule).
    final exhausted =
        failure != null ||
        missingModel ||
        (timedOut
            ? await failsAfterTimeout(payload, queued.attempts, tries: maxTries)
            : _exhausted(payload, queued.attempts, maxTries) ||
                  await _exceptionsExhausted(payload));
    await _announce(
      JobExceptionOccurred(
        connection: driver.name,
        queue: queued.queue,
        jobName: payload.jobName,
        jobId: queued.id,
        error: error,
        willRetry: !exhausted,
        uuid: payload.uuid,
        attempt: queued.attempts,
        stackTrace: trace,
      ),
    );
    if (timedOut && !exhausted) {
      // The handler's future was abandoned, not cancelled: it is still
      // running while the job is released for another attempt. The worker
      // that sees this stops after its bookkeeping, so the process is
      // restarted (as Laravel kills a worker on timeout) and attempt 1 does
      // not go on next to attempt 2.
      timedOutAndReleased++;
    }
    // A job that failed for good must not keep later dispatches waiting.
    if (exhausted &&
        debounce != null &&
        await debounce.get<String>(debounced) == owner) {
      await debounce.forget(debounced);
    }
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

  /// Laravel's `markJobAsFailedIfAlreadyExceedsMaxAttempts`: past
  /// `retryUntil`, or reserved more times than [maxTries] allows.
  bool _alreadyExceeded(JobPayload payload, int attempts, int maxTries) {
    final retryUntil = payload.retryUntil;
    if (retryUntil != null) {
      return _clock().millisecondsSinceEpoch ~/ 1000 > retryUntil;
    }
    return maxTries > 0 && attempts > maxTries;
  }

  /// Whether a job that ran past its timeout on attempt [attempts] fails
  /// now rather than being tried again: Laravel's timeout handler, in its
  /// order:
  /// 1. its tries are used up, or `retryUntil` has passed ([tries], when
  ///    given, overriding the job's own as `--tries` does);
  /// 2. this timeout is its last allowed exception (`maxExceptions`, the
  ///    `job-exceptions:<uuid>` count goes up by one);
  /// 3. it fails on a timeout ([Job.failOnTimeout]).
  ///
  /// [process] applies it to a timeout its own timer saw. A supervisor that
  /// killed a worker blocked past the timeout asks it for the job the worker
  /// held: it reads only [payload] and the exception count, never the job's
  /// code (no `fromJson`, no hook, no listener).
  Future<bool> failsAfterTimeout(
    JobPayload payload,
    int attempts, {
    int? tries,
  }) async =>
      _exhausted(payload, attempts, tries ?? payload.maxTries) ||
      await _exceptionsExhausted(payload) ||
      payload.failOnTimeout;

  /// Fails [queued], just reserved, without running it, with [error]:
  /// `failed_jobs`, the job's `failed()` hook and `JobFailed`, as a job that
  /// fails after running does, and its unique lock and debounce released.
  /// For a job a supervisor decided must fail ([WorkerOptions.failBeforeRun]),
  /// such as one whose worker was killed past its timeout. A job that cannot
  /// be built (`fromJson` throws) fails without its hook.
  Future<void> failReserved(
    QueueDriver driver,
    QueuedJob queued,
    Object error, [
    StackTrace? stackTrace,
  ]) async {
    final payload = queued.payload;
    Job? job;
    try {
      job = registry.make(payload.jobName, payload.data);
    } on Object {
      job = null;
    }
    final owner = payload.debounceOwner;
    final debounce = owner == null || job == null
        ? null
        : debounceStore?.call();
    if (debounce != null) {
      final key = debounceKey(job!);
      if (await debounce.get<String>(key) == owner) {
        await debounce.forget(key);
      }
    }
    await _fail(
      driver,
      queued,
      error,
      stackTrace ?? StackTrace.current,
      job: job,
    );
  }

  /// Laravel's `markJobAsFailedIfWillExceedMaxExceptions`: counts this
  /// exception and answers whether it is the job's last allowed one.
  Future<bool> _exceptionsExhausted(JobPayload payload) async {
    final max = payload.maxExceptions;
    final store = exceptionStore?.call();
    if (max == null || max <= 0 || store == null) {
      return false;
    }
    final key = 'job-exceptions:${payload.uuid}';
    if (await store.get<int>(key) == null) {
      await store.put(key, 0, ttl: const Duration(days: 1));
    }
    if (await store.increment(key) >= max) {
      await store.forget(key);
      return true;
    }
    return false;
  }

  /// Warns once per job when its timeout reaches the driver's
  /// `retry_after`: past it, another worker may take the job while it runs
  /// (Laravel: "retry_after should always be larger than the timeout").
  void _warnRetryAfter(QueueDriver driver, String job, Duration timeout) {
    if (driver is! ReservingQueueDriver ||
        timeout < driver.retryAfter ||
        !_retryAfterWarned.add('${driver.name}:$job')) {
      return;
    }
    logger?.warning(
      'Job $job may run for ${timeout.inSeconds}s, which is not less than '
      'retry_after (${driver.retryAfter.inSeconds}s) of the [${driver.name}] '
      'queue. The worker keeps a running job reserved, but a worker that '
      'stops responding leaves it to another only after retry_after: set '
      'QUEUE_RETRY_AFTER above the longest job timeout.',
    );
  }

  /// Keeps [queued] reserved while it runs: extends it every [every]
  /// (half `retry_after` by default), so a job running longer than that is
  /// not reserved again by another worker and run twice at once. An
  /// [ExtendingQueueDriver] says until when; [onExtended] hears it.
  ///
  /// One extension at a time: a tick while the previous one is still on
  /// its way (a slow database) is skipped, not queued behind it.
  Timer? _heartbeat(
    QueueDriver driver,
    QueuedJob queued, {
    Duration? every,
    void Function(QueuedJob job, DateTime until)? onExtended,
  }) {
    if (driver is! ReservingQueueDriver) {
      return null;
    }
    final interval = every ?? driver.retryAfter ~/ 2;
    if (interval <= Duration.zero) {
      return null;
    }
    var inFlight = false;
    Future<void> extendOnce() async {
      DateTime? until;
      try {
        if (driver is ExtendingQueueDriver) {
          until = await driver.extend(queued);
        } else {
          await driver.touch(queued);
        }
      } on Object catch (error) {
        logger?.warning(
          'Could not extend the reservation of job ${queued.id}: $error',
        );
      } finally {
        inFlight = false;
      }
      if (until != null && onExtended != null) {
        try {
          onExtended(queued, until);
        } on Object catch (error, stackTrace) {
          logger?.error(
            'onReservationExtended failed for job ${queued.id}',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }

    // A wall-clock timer: a frozen test clock must not stop it.
    return Timer.periodic(interval, (_) {
      if (inFlight) {
        return;
      }
      inFlight = true;
      unawaited(extendOnce());
    });
  }

  /// Dispatches a job lifecycle event. A listener that throws is logged:
  /// it must not skip the bookkeeping around it (a job left reserved, a
  /// release or a failure not recorded, a unique lock never released).
  Future<void> _announce<E extends Object>(E event) async {
    try {
      await events.dispatch(event);
    } on Object catch (error, stackTrace) {
      logger?.error(
        'A $E listener threw; the job goes on',
        error: error,
        stackTrace: stackTrace,
      );
    }
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
      // Both formats, whichever release dispatched it (ADR-041).
      for (final key in QueueLockKeys.uniqueKeysOf(
        unique,
        displayName: payload.displayName,
        jobName: payload.jobName,
      )) {
        await uniqueLockRelease?.call(key);
      }
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
    final failedId = await failedJobs.log(
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
    await _announce(
      JobFailed(
        connection: driver.name,
        queue: queued.queue,
        jobName: queued.payload.jobName,
        jobId: queued.id,
        error: error,
        uuid: queued.payload.uuid,
        stackTrace: stackTrace,
        failedId: failedId,
      ),
    );
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Another retry of all failed jobs holds the lock
/// ([QueueManager.retryAllFailed]): two at once would push the same jobs
/// twice.
final class RetryAllRunningException extends DaravelException {
  /// Failed jobs are already being retried elsewhere.
  const RetryAllRunningException()
    : super('The failed jobs are already being retried; try again later.');
}

/// A failed job [QueueManager.retryAllFailed] left in `failed_jobs`, with
/// why: its payload could not be read, so it cannot run again.
typedef SkippedFailedJob = ({Object id, String uuid, String reason});

/// What one call of [QueueManager.retryAllFailed] did.
final class RetryAllResult {
  /// The outcome of one call.
  const RetryAllResult({
    required this.retried,
    required this.skipped,
    required this.skippedCount,
    required this.remaining,
    required this.after,
    required this.upTo,
  });

  /// The uuids of the jobs pushed back onto their queues.
  final List<String> retried;

  /// The first [QueueManager.maxSkippedReported] jobs left behind.
  final List<SkippedFailedJob> skipped;

  /// How many jobs were left behind.
  final int skippedCount;

  /// How many failed jobs up to [upTo] are still to retry: the call
  /// stopped at its limit or budget. 0 when it is done.
  final int remaining;

  /// The id to continue from in the next call.
  final int after;

  /// The largest id this run retries (the last failed job when it began):
  /// jobs failing again during it get later ids and are not retried in the
  /// same run. Null when there was nothing to retry, or when the failed job
  /// provider is not a [FailedJobPages].
  final int? upTo;
}

/// Connections, dispatching, unique jobs and faking (Laravel `QueueManager`
/// + `Bus::dispatch`).
final class QueueManager {
  /// A manager of the connections in [config].
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

  /// The queue settings.
  final QueueConfig config;

  /// The registered jobs.
  final JobRegistry registry;

  /// The event dispatcher.
  final EventDispatcher events;

  /// The container jobs run in.
  final Container container;

  /// Runs reserved jobs.
  final JobProcessor processor;

  /// The database of the database queue, when there is one.
  final DatabaseManager? database;

  /// Store for unique-job locks (`ShouldBeUnique`).
  final CacheRepository? lockStore;

  /// Where [restart] and [pause] signals live (defaults to [lockStore]):
  /// the commands run in a process of their own, so it must be a store the
  /// workers read too.
  CacheRepository? get signalStore => _signalStore ?? lockStore;
  final CacheRepository? _signalStore;

  /// Logs dispatches and failures.
  final Logger? logger;

  final Map<String, QueueDriver Function()> _factories = {};
  final Map<String, QueueDriver> _connections = <String, QueueDriver>{};
  QueueFake? _fake;

  /// Registers a connection factory.
  void extend(String name, QueueDriver Function() factory) =>
      _factories[name] = factory;

  /// The names of the configured connections.
  Iterable<String> get connectionNames => _factories.keys;

  /// Pushes the failed job [id] (its `failed_jobs` id or uuid) back onto
  /// the queue it failed on and forgets it, as `queue:retry` does (its
  /// unique lock is not taken again); the job, or null when no failed job
  /// matches.
  Future<FailedJob?> retryFailed(Object id) async {
    final failed = await processor.failedJobs.find(id);
    if (failed == null) {
      return null;
    }
    await _retry(failed);
    return failed;
  }

  /// The most skipped jobs a [RetryAllResult] lists ([RetryAllResult.
  /// skippedCount] counts them all).
  static const int maxSkippedReported = 100;

  /// [retryFailed] for every failed job (of [queue] when given), oldest
  /// first, a page of [pageSize] at a time (`queue:retry all`, Horizon's
  /// retry-all).
  ///
  /// One call stops after [limit] jobs or once [budget] has passed, and
  /// says how many are [RetryAllResult.remaining]; pass its
  /// [RetryAllResult.after] and [RetryAllResult.upTo] to the next call to
  /// go on. The run never goes past the last failed job there was when it
  /// began ([upTo]), so a job that fails again at once is not retried
  /// again by the same run.
  ///
  /// A job whose payload cannot be read stays in `failed_jobs` and is
  /// reported as skipped (Laravel pushes such a payload as `null`); the
  /// others are still retried. Each call holds the lock `queue:retry-all`
  /// in [signalStore] (shared by the processes): a second call while it
  /// runs, from another request or `dartisan`, throws
  /// [RetryAllRunningException] instead of pushing the same jobs twice.
  Future<RetryAllResult> retryAllFailed({
    String? queue,
    int? limit,
    Duration? budget,
    int after = 0,
    int? upTo,
    int pageSize = 500,
    void Function(FailedJob failed)? onRetried,
    void Function(FailedJob failed, Object error)? onSkipped,
  }) async {
    // Longer than a call is allowed to take, so it does not expire under
    // it; a call without a budget (one that runs to the end) gets an hour.
    final ttl = budget == null
        ? const Duration(hours: 1)
        : budget * 3 + const Duration(seconds: 30);
    final lock = signalStore?.lock('queue:retry-all', ttl: ttl);
    if (lock != null && !await lock.acquire()) {
      throw const RetryAllRunningException();
    }
    try {
      return await _retryAll(
        queue: queue,
        limit: limit,
        budget: budget,
        after: after,
        upTo: upTo,
        pageSize: pageSize,
        onRetried: onRetried,
        onSkipped: onSkipped,
      );
    } finally {
      await lock?.release();
    }
  }

  Future<RetryAllResult> _retryAll({
    required String? queue,
    required int? limit,
    required Duration? budget,
    required int after,
    required int? upTo,
    required int pageSize,
    required void Function(FailedJob failed)? onRetried,
    required void Function(FailedJob failed, Object error)? onSkipped,
  }) async {
    final watch = Stopwatch()..start();
    final retried = <String>[];
    final skipped = <SkippedFailedJob>[];
    var skippedCount = 0;
    var handled = 0;
    bool stop() =>
        (limit != null && handled >= limit) ||
        (budget != null && watch.elapsed >= budget);
    Future<void> handle(FailedJob failed) async {
      handled++;
      final JobPayload payload;
      try {
        payload = _retryPayload(failed);
      } on Object catch (error) {
        skippedCount++;
        if (skipped.length < maxSkippedReported) {
          skipped.add((id: failed.id, uuid: failed.uuid, reason: '$error'));
        }
        onSkipped?.call(failed, error);
        return;
      }
      await _push(failed, payload);
      retried.add(failed.uuid);
      onRetried?.call(failed);
    }

    final failedJobs = processor.failedJobs;
    if (failedJobs is! FailedJobPages) {
      // No pages: all of them at once, as before.
      final all = [
        for (final failed in await failedJobs.all())
          if (queue == null || failed.queue == queue) failed,
      ];
      var at = 0;
      for (; at < all.length && !stop(); at++) {
        await handle(all[at]);
      }
      return RetryAllResult(
        retried: retried,
        skipped: skipped,
        skippedCount: skippedCount,
        remaining: all.length - at,
        after: 0,
        upTo: null,
      );
    }
    final pages = failedJobs as FailedJobPages;
    final bound = upTo ?? await pages.lastId(queue: queue);
    var cursor = after;
    if (bound != null) {
      pages:
      while (!stop()) {
        final page = await pages.page(
          after: cursor,
          upTo: bound,
          limit: pageSize,
          queue: queue,
        );
        if (page.isEmpty) {
          break;
        }
        for (final failed in page) {
          if (stop()) {
            break pages;
          }
          cursor = failed.id as int;
          await handle(failed);
        }
      }
    }
    return RetryAllResult(
      retried: retried,
      skipped: skipped,
      skippedCount: skippedCount,
      remaining: bound == null
          ? 0
          : await pages.countBetween(after: cursor, upTo: bound, queue: queue),
      after: cursor,
      upTo: bound,
    );
  }

  Future<void> _retry(FailedJob failed) => _push(failed, _retryPayload(failed));

  /// The payload [failed] runs again with (its unique lock is not taken
  /// again); throws when it cannot be read.
  static JobPayload _retryPayload(FailedJob failed) =>
      JobPayload.fromJson(<String, Object?>{
        ...JobPayload.decode(failed.payload).toJson(),
        'uniqueKey': null,
      });

  Future<void> _push(FailedJob failed, JobPayload payload) async {
    await connection(failed.connection).push(payload, queue: failed.queue);
    await processor.failedJobs.forget(failed.id);
  }

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
  final Map<Type, ({String? queue, String? connection})> _routes = {};

  /// Laravel's `Queue::route()`: where jobs of type [T] go, kept in one place
  /// instead of on each class. A dispatch's own `onQueue` and the job's own
  /// `queue` still win. The type must match exactly, as a route is looked up
  /// by the job's class.
  void route<T extends Job>({String? queue, String? connection}) =>
      _routes[T] = (queue: queue, connection: connection);

  /// Pushes [job] onto its queue; returns its id.
  Future<Object?> push(
    Job job, {
    String? queue,
    String? connection,
    Duration? delay,
    bool? afterCommit,
  }) async {
    // Before the fake, so a test catches the mistake too.
    if (job.uniqueId != null && job.debounceFor != null) {
      throw StateError('A debounced job cannot also be unique.');
    }
    final fake = _fake;
    final routed = _routes[job.runtimeType];
    final targetQueue =
        queue ?? job.queue ?? routed?.queue ?? config.defaultQueue;
    final targetConnection =
        connection ??
        job.connection ??
        routed?.connection ??
        config.defaultConnection;
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
      // Laravel's PendingDispatch::shouldDispatch and Queue::enqueueUsing:
      // the unique lock is taken now, at dispatch (the debounce owner only
      // at the push, after the commit: [_takeLocks]),
      // so a second transaction dispatching the same id is refused here and
      // not after its commit; a rollback gives it back, before a retry of
      // `transaction(attempts:)` runs the body again; the push itself waits
      // for the commit (G1.5).
      final locks = await _takeLocks(job, delay);
      if (locks == null) {
        return null;
      }
      db.afterRollback(locks.release);
      await db.afterCommit(() async {
        try {
          await _pushHeld(job, targetQueue, targetConnection, locks);
        } on Object catch (error, stackTrace) {
          // Logged once, by the database manager (an after-commit callback
          // that failed); counted here. A listener that throws must not
          // replace the push's own error.
          try {
            await events.dispatch(
              JobPushFailedAfterCommit(
                connection: targetConnection,
                queue: targetQueue,
                jobName: job.jobName,
                error: error,
              ),
            );
          } on Object catch (listenerError, listenerTrace) {
            logger?.error(
              'A JobPushFailedAfterCommit listener failed',
              error: listenerError,
              stackTrace: listenerTrace,
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      });
      return null;
    }
    return _pushNow(job, targetQueue, targetConnection, delay);
  }

  /// `DebounceLock::acquire`: the last dispatch owns the key, and each job
  /// checks it when it runs, so this works on every driver. Answers the
  /// token, whether the burst passed [Job.debounceMaxWait], and how to
  /// undo both when the push then fails (the previous owner, still queued,
  /// must stay the one that runs).
  Future<(String, bool, Future<void> Function())> _acquireDebounce(
    CacheRepository store,
    Job job,
    Duration debounce,
  ) async {
    final key = JobProcessor.debounceKey(job);
    final tenfold = debounce * 10;
    final ttl = tenfold > const Duration(minutes: 5)
        ? tenfold
        : const Duration(minutes: 5);
    final owner = const Uuid().v4();
    final previous = await store.get<String>(key);
    await store.put(key, owner, ttl: ttl);
    // The previous release's key too, for its workers during a deploy
    // (ADR-041); `first_dispatched_at` lives under Laravel's key only.
    final legacy = QueueLockKeys.legacyKeys
        ? JobProcessor.legacyDebounceKey(job)
        : null;
    final previousLegacy = legacy == null
        ? null
        : await store.get<String>(legacy);
    if (legacy != null) {
      await store.put(legacy, owner, ttl: QueueLockKeys.legacyTtl(ttl));
    }
    final firstKey = '$key:first_dispatched_at';
    int? restoreFirst;
    var forgetFirst = false;
    Future<void> undo() async {
      if (await store.get<String>(key) == owner) {
        if (previous == null) {
          await store.forget(key);
        } else {
          await store.put(key, previous, ttl: ttl);
        }
      }
      if (legacy != null && await store.get<String>(legacy) == owner) {
        if (previousLegacy == null) {
          await store.forget(legacy);
        } else {
          await store.put(
            legacy,
            previousLegacy,
            ttl: QueueLockKeys.legacyTtl(ttl),
          );
        }
      }
      if (forgetFirst) {
        await store.forget(firstKey);
      } else if (restoreFirst case final first?) {
        await store.put(firstKey, first, ttl: ttl);
      }
    }

    final maxWait = job.debounceMaxWait;
    if (maxWait == null) {
      return (owner, false, undo);
    }
    final now = Clock.now().millisecondsSinceEpoch;
    final first = await store.get<int>(firstKey);
    if (first == null) {
      await store.put(firstKey, now, ttl: ttl);
      forgetFirst = true;
      return (owner, false, undo);
    }
    if (now - first >= maxWait.inMilliseconds) {
      await store.forget(firstKey);
      restoreFirst = first;
      return (owner, true, undo);
    }
    return (owner, false, undo);
  }

  Future<Object?> _pushNow(
    Job job,
    String queue,
    String connection,
    Duration? delay,
  ) async {
    final locks = await _takeLocks(job, delay);
    if (locks == null) {
      return null;
    }
    return _pushHeld(job, queue, connection, locks);
  }

  /// Takes [job]'s unique lock: null when it is held by a dispatch still
  /// pending (the job is skipped). The debounce owner is not taken here but
  /// at the push ([_pushHeld]): taken at a dispatch inside a transaction, it
  /// would make the job still queued drop itself while the transaction is
  /// open, and a rollback would then lose both.
  Future<_DispatchLocks?> _takeLocks(Job job, Duration? delay) async {
    String? uniqueKey;
    Lock? unique;
    Lock? legacyUnique;
    final uniqueId = job.uniqueId;
    if (uniqueId != null) {
      final store = lockStore;
      if (store == null) {
        throw const ConfigException('Unique jobs need a cache lock store.');
      }
      uniqueKey = QueueLockKeys.unique(
        job.displayName,
        uniqueId,
        hashed: job.uniqueKeyHashesDisplayName,
      );
      // Laravel's `uniqueFor` 0 is a lock that never expires; 365 days
      // here, so a lock left behind recovers (a deliberate difference,
      // ADR-041).
      final ttl = job.uniqueFor == Duration.zero
          ? const Duration(days: 365)
          : job.uniqueFor;
      // The previous release's key first, then Laravel's: an instance of
      // either release refuses the other's dispatch during a deploy.
      if (QueueLockKeys.legacyKeys) {
        legacyUnique = store.lock(
          QueueLockKeys.legacyUnique(job.jobName, uniqueId),
          ttl: QueueLockKeys.legacyTtl(ttl),
        );
        if (!await legacyUnique.acquire()) {
          logger?.debug(
            'Unique job ${job.displayName} [$uniqueId] already pending; '
            'skipped.',
          );
          return null;
        }
      }
      unique = store.lock(uniqueKey, ttl: ttl);
      if (!await unique.acquire()) {
        await legacyUnique?.release();
        logger?.debug(
          'Unique job ${job.displayName} [$uniqueId] already pending; skipped.',
        );
        return null;
      }
    }
    return _DispatchLocks(uniqueKey, unique, delay, job, logger)
      ..legacyUnique = legacyUnique;
  }

  /// Pushes [job] holding [locks], taking its debounce owner first; a
  /// failed push gives both back.
  Future<Object?> _pushHeld(
    Job job,
    String queue,
    String connection,
    _DispatchLocks locks,
  ) async {
    try {
      final debounce = job.debounceFor;
      if (debounce != null) {
        final store = lockStore;
        if (store == null) {
          throw const ConfigException('Debounced jobs need a cache store.');
        }
        final (token, overdue, undo) = await _acquireDebounce(
          store,
          job,
          debounce,
        );
        locks
          ..owner = token
          ..undoDebounce = undo
          ..wait ??= overdue ? Duration.zero : debounce;
      }
      final payload = JobPayload.forJob(
        job,
        uniqueKey: locks.uniqueKey,
        debounceOwner: locks.owner,
      );
      return await this
          .connection(connection)
          .push(payload, queue: queue, delay: locks.wait);
    } catch (_) {
      // Nothing was queued: a unique lock left behind would skip every
      // dispatch of this id for `uniqueFor` (a year by default), and a
      // debounce owner left behind would drop the dispatch still queued.
      await locks.release();
      rethrow;
    }
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

  /// Undoes `fake()`.
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
  /// How a worker runs: which queues, how long, how many jobs.
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
    this.memory,
    this.onReserved,
    this.failBeforeRun,
    this.onFinished,
    this.extendEvery,
    this.onReservationExtended,
  });

  /// Asked about each job after [onReserved] and before it is processed:
  /// an error to fail it with at once, without running it
  /// ([JobProcessor.failReserved]), or null to process it. For a supervisor
  /// that decided a job's fate while it could not act on it itself
  /// (`daravel_horizon` fails a job here whose last worker it killed past
  /// a timeout the job fails on). An error it throws is logged and the job
  /// is processed.
  final FutureOr<Object?> Function(QueuedJob job)? failBeforeRun;

  /// Called with each job the moment the driver reserved it, before it is
  /// decoded into a job (`fromJson`), announced (`JobProcessing`) or run:
  /// synchronously, so a supervisor hears of the job before anything of the
  /// job's own can block the isolate (`daravel_horizon` reports it then).
  /// An error it throws is logged and the job is processed all the same.
  /// Not called for a reservation the driver makes but has not returned
  /// yet (inside its own I/O).
  final void Function(QueuedJob job)? onReserved;

  /// Called with each job [onReserved] was told of once the worker is done
  /// with it, whatever happened: processed, failed, released, deleted
  /// (a superseded debounce), or failed before it ran (an unknown name,
  /// `fromJson` throwing, its tries used up). Synchronously, after
  /// `JobProcessed`/`JobFailed` when there are any; not every way out has
  /// an event, so a supervisor clears what it reported here. An error it
  /// throws is logged.
  final void Function(QueuedJob job)? onFinished;

  /// How often a running job's reservation is extended on a queue that
  /// reserves (`ReservingQueueDriver.touch`): half `retry_after` when
  /// null. A supervisor that kills a blocked job before its reservation
  /// ends (`daravel_horizon`) extends more often, so an extension reaches
  /// it in time. Must be above zero ([QueueWorker.run] refuses it
  /// otherwise); each extension is one write to the queue per running job.
  final Duration? extendEvery;

  /// Called with a running job and the new end of its reservation each time
  /// an [ExtendingQueueDriver] extended it (not when nothing changed). An
  /// error it throws is logged.
  final void Function(QueuedJob job, DateTime until)? onReservationExtended;

  /// The connection worked; the default one when null.
  final String? connection;

  /// Queues polled in priority order.
  final List<String> queues;

  /// Overrides the job's `tries` (`null` = use the job's own value).
  final int? tries;

  /// The waits between attempts, overriding the jobs' own.
  final List<Duration>? backoff;

  /// How long one job may run.
  final Duration? timeout;

  /// How long to wait when the queue is empty.
  final Duration sleep;

  /// Stop after this many jobs (`--max-jobs`).
  final int? maxJobs;

  /// Stop after this long (`--max-time`).
  final Duration? maxTime;

  /// Stop when the queue is empty (`--stop-when-empty`).
  final bool stopWhenEmpty;

  /// Laravel's `--memory`: stop ([QueueWorker.exitMemoryLimit]) once the
  /// process's resident memory reaches this many megabytes after a job, for
  /// the process manager to start a fresh worker. No limit when null.
  final int? memory;
}

/// Polls queues and processes jobs (`dartisan queue:work`).
final class QueueWorker {
  /// A worker of [manager]'s queues.
  QueueWorker(this.manager, {this._logger});

  /// The queues worked.
  final QueueManager manager;
  final Logger? _logger;
  bool _stop = false;
  bool _paused = false;

  /// The jobs this worker has processed.
  int processed = 0;

  /// Laravel's `EXIT_MEMORY_LIMIT`: what [run] returns once
  /// [WorkerOptions.memory] is reached.
  static const int exitMemoryLimit = 12;

  /// Set when the worker must be restarted rather than resumed: a job
  /// timed out and was released while its handler still runs in this
  /// process. [run] then returns 1, like `queue:restart`.
  bool _restart = false;

  /// Errors of the database or the cache in a row (an outage): the worker
  /// waits longer between polls ([errorBackoff]) and logs less.
  int _errors = 0;

  /// When an error was last logged in full (wall clock), and how many were
  /// left out since.
  DateTime? _errorLoggedAt;
  int _errorsUnlogged = 0;

  final math.Random _random = math.Random();

  /// Stops after the current job.
  void stop() {
    _stop = true;
    _wakeIdle();
  }

  /// Completed by [stop] or [reassign] while the worker waits for work.
  Completer<void>? _idle;

  void _wakeIdle() {
    final idle = _idle;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }

  /// The queues polled, set by [run] from [WorkerOptions.queues] and
  /// changed by [reassign]; null outside [run] until [reassign].
  List<String>? _queues;

  /// The queues this worker polls now, in priority order (empty before
  /// [run] when [reassign] was not called).
  List<String> get queues => _queues ?? const <String>[];

  /// Polls [queues] (in priority order) from the next job on, instead of
  /// [WorkerOptions.queues]: for a supervisor moving workers between queues
  /// (`daravel_horizon`'s auto-scaling). The job running finishes first; an
  /// idle worker polls the new queues at once. Called before [run], it
  /// replaces the queues that run starts with.
  void reassign(List<String> queues) {
    _queues = List<String>.unmodifiable(queues);
    _logger?.info('Worker reassigned to [${queues.join(', ')}].');
    _wakeIdle();
  }

  /// Stops taking new jobs (the current one finishes) until [resume]; for
  /// embedding supervisors. [QueueManager.pause] pauses a queue for every
  /// worker instead.
  void pause() => _paused = true;

  /// Takes jobs again after [pause].
  void resume() => _paused = false;

  /// Whether [pause] is in effect.
  bool get paused => _paused;

  /// The wait after [errors] failed polls in a row: [sleep] after the
  /// first, doubled for each further one, at most a minute (never less than
  /// [sleep]). The worker adds up to 20 % of jitter below it.
  static Duration errorBackoff(Duration sleep, int errors) {
    const cap = Duration(minutes: 1);
    if (errors <= 1 || sleep >= cap) {
      return sleep;
    }
    var wait = sleep < const Duration(milliseconds: 1)
        ? const Duration(milliseconds: 1)
        : sleep;
    for (var i = 1; i < errors && wait < cap; i++) {
      wait *= 2;
    }
    return wait < cap ? wait : cap;
  }

  /// Runs until stopped, [WorkerOptions.maxJobs]/[WorkerOptions.maxTime]
  /// are reached, or the queue is empty with [WorkerOptions.stopWhenEmpty].
  /// Returns the exit code: 0; 1 when stopped by `queue:restart` (or for a
  /// restart after a timeout); [exitMemoryLimit] past
  /// [WorkerOptions.memory]. Errors of the database or the cache (a worker
  /// started during an outage, a signal store that fails) are logged and
  /// retried with a growing wait; they do not end it.
  Future<int> run(WorkerOptions options) async {
    if (options.extendEvery case final every? when every <= Duration.zero) {
      throw ArgumentError.value(every, 'extendEvery', 'must be above zero');
    }
    _stop = false;
    _restart = false;
    _errors = 0;
    final started = DateTime.now().toUtc();
    final driver = manager.connection(options.connection);
    _queues ??= List<String>.unmodifiable(options.queues);
    _logger?.info(
      'Processing jobs from [${queues.join(', ')}] on connection '
      '[${driver.name}].',
    );
    final timeout = options.timeout;
    if (timeout != null &&
        driver is ReservingQueueDriver &&
        timeout >= driver.retryAfter) {
      _logger?.warning(
        '--timeout=${timeout.inSeconds} is not less than retry_after '
        '(${driver.retryAfter.inSeconds}s) of the [${driver.name}] queue: a '
        'job of a worker that stops responding runs again elsewhere only '
        'after retry_after. Set QUEUE_RETRY_AFTER above the timeout.',
      );
    }
    // The restart signal at start; read again until a read succeeds.
    var (markKnown, restartMark) = await _restartSignal();
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
        final memory = options.memory;
        if (ran && memory != null && _memoryExceeded(memory)) {
          _logger?.warning(
            'Memory limit of ${memory}MB reached; the worker stops for a '
            'fresh one.',
          );
          return exitMemoryLimit;
        }
        final (read, restart) = await _restartSignal();
        if (read && !markKnown) {
          markKnown = true;
          restartMark = restart;
        } else if (read && restart != null && restart != restartMark) {
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
      _queues = null;
      if (driver is WakeableQueueDriver) {
        try {
          await driver.stopWaiting();
        } on Object catch (error, stackTrace) {
          _reportError('Could not stop waiting for jobs', error, stackTrace);
        }
      }
    }
    return _restart ? 1 : 0;
  }

  static bool _memoryExceeded(int megabytes) {
    try {
      return ProcessInfo.currentRss >= megabytes * 1024 * 1024;
    } on Object {
      return false;
    }
  }

  /// Whether the `queue:restart` timestamp could be read, and its value: a
  /// signal store that fails is reported and read again on the next loop.
  Future<(bool, int?)> _restartSignal() async {
    try {
      return (true, await manager.restartRequestedAt());
    } on Object catch (error, stackTrace) {
      _failed('Could not read the queue:restart signal', error, stackTrace);
      return (false, null);
    }
  }

  /// Up to [WorkerOptions.sleep] (longer during an outage, see
  /// [errorBackoff]): less when the driver wakes the worker on a push
  /// ([WakeableQueueDriver]) or [stop] is called.
  Future<void> _waitForWork(QueueDriver driver, WorkerOptions options) async {
    final idle = _idle = Completer<void>();
    try {
      if (_errors > 0) {
        // Jitter, so workers that failed together do not retry together.
        final backoff = errorBackoff(options.sleep, _errors);
        final jittered = backoff * (0.8 + 0.2 * _random.nextDouble());
        final wait = jittered < options.sleep ? options.sleep : jittered;
        await Future.any([Future<void>.delayed(wait), idle.future]);
        return;
      }
      try {
        await Future.any([
          if (driver is WakeableQueueDriver)
            driver.waitForWork(_queues ?? options.queues, options.sleep)
          else
            Future<void>.delayed(options.sleep),
          idle.future,
        ]);
      } on Object catch (error, stackTrace) {
        // The wake-up connection (a LISTEN) could not be opened: sleep.
        _failed('Could not wait for jobs', error, stackTrace);
        await Future.any([Future<void>.delayed(options.sleep), idle.future]);
      }
    } finally {
      _idle = null;
    }
  }

  /// Counts an error of the outage under way and reports it.
  void _failed(String message, Object error, StackTrace stackTrace) {
    _errors++;
    _reportError(message, error, stackTrace);
  }

  /// Logs the first error of an outage in full, then at most one a minute
  /// with the number left out, instead of a stack trace on every poll.
  void _reportError(String message, Object error, StackTrace stackTrace) {
    final now = DateTime.now();
    final last = _errorLoggedAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      _errorsUnlogged++;
      return;
    }
    final unlogged = _errorsUnlogged;
    _errorLoggedAt = now;
    _errorsUnlogged = 0;
    _logger?.error(
      unlogged == 0
          ? '$message; retrying'
          : '$message; retrying ($unlogged more errors since the last report)',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// A poll succeeded: the outage under way, if any, is over.
  void _recovered() {
    if (_errors > 1) {
      _logger?.info('Queue worker recovered after $_errors errors in a row.');
    }
    _errors = 0;
  }

  /// Whether [queue] is paused ([QueueManager.pause]). A flag that cannot
  /// be read (the signal store fails) is reported and taken as not paused:
  /// the jobs keep running rather than wait for the store.
  Future<bool> _isPaused(String queue, WorkerOptions options) async {
    try {
      return await manager.isPaused(queue, connection: options.connection);
    } on Object catch (error, stackTrace) {
      _reportError(
        'Could not read the queue:pause flag of [$queue]; working it',
        error,
        stackTrace,
      );
      return false;
    }
  }

  /// Processes at most one job; returns whether one was found. Paused
  /// workers and paused queues ([QueueManager.pause]) are skipped. The
  /// queues are those of [reassign] when set, else [WorkerOptions.queues].
  Future<bool> runNextJob(QueueDriver driver, WorkerOptions options) async {
    if (_paused) {
      return false;
    }
    final processor = manager.processor;
    for (final queue in _queues ?? options.queues) {
      try {
        if (await _isPaused(queue, options)) {
          continue;
        }
        final job = await driver.pop(queue);
        _recovered();
        if (job == null) {
          continue;
        }
        final reserved = options.onReserved;
        if (reserved != null) {
          try {
            reserved(job);
          } on Object catch (error, stackTrace) {
            // A listener's failure must not lose the job it was told of.
            _logger?.error(
              'onReserved failed for job ${job.id}',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        final before = processor.timedOutAndReleased;
        try {
          Object? failWith;
          if (options.failBeforeRun case final ask?) {
            try {
              failWith = await ask(job);
            } on Object catch (error, stackTrace) {
              _logger?.error(
                'failBeforeRun failed for job ${job.id}; it runs',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
          if (failWith != null) {
            await processor.failReserved(driver, job, failWith);
          } else {
            await processor.process(
              driver,
              job,
              tries: options.tries,
              backoff: options.backoff,
              timeout: options.timeout,
              extendEvery: options.extendEvery,
              onReservationExtended: options.onReservationExtended,
            );
          }
        } finally {
          final finished = options.onFinished;
          if (finished != null) {
            try {
              finished(job);
            } on Object catch (error, stackTrace) {
              _logger?.error(
                'onFinished failed for job ${job.id}',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        }
        if (processor.timedOutAndReleased != before) {
          _logger?.warning(
            'Job ${job.payload.displayName} timed out and was released while '
            'its handler still runs; the worker stops for a restart.',
          );
          _restart = true;
          _stop = true;
        }
        return true;
      } on CorruptPayloadException catch (error, stackTrace) {
        // The driver removed the row; it goes to failed_jobs like any job
        // that cannot run, instead of ending the worker.
        _logger?.error(
          'Job ${error.id} failed',
          error: error,
          stackTrace: stackTrace,
        );
        try {
          await processor.failedJobs.log(
            connection: driver.name,
            queue: error.queue,
            payload: error.raw,
            exception: '$error\n$stackTrace',
          );
        } on Object catch (logError, logTrace) {
          _failed(
            'Could not record failed job ${error.id}',
            logError,
            logTrace,
          );
        }
        return true;
      } on Object catch (error, stackTrace) {
        // A transient failure of the database or the cache (pop, the pause
        // flag, bookkeeping): reported, then the loop waits as if the queue
        // were empty, longer while it lasts, instead of the worker dying.
        _failed('Queue worker error on [$queue]', error, stackTrace);
        return false;
      }
    }
    return false;
  }
}

/// The unique lock and debounce owner one dispatch holds until its push
/// (G1.5): given back when the push fails or its transaction rolls back.
final class _DispatchLocks {
  _DispatchLocks(this.uniqueKey, this.unique, this.wait, this.job, this.logger);

  final String? uniqueKey;
  final Lock? unique;
  Duration? wait;
  final Job job;
  final Logger? logger;
  String? owner;
  Future<void> Function()? undoDebounce;

  /// The previous release's unique lock, taken with [unique] (ADR-041).
  Lock? legacyUnique;
  bool _released = false;

  /// Gives both back, once.
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    try {
      await unique?.release();
      await legacyUnique?.release();
      await undoDebounce?.call();
    } on Object catch (error, stackTrace) {
      logger?.error(
        'Could not undo the locks of a failed push of ${job.displayName}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
