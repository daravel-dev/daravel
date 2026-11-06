import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';

import 'messages.dart';
import 'store/process_store.dart';

/// What a worker isolate gets when it is spawned. Sent once, at spawn, so
/// it may hold the application factory (a top-level function).
final class HorizonWorkerStart {
  /// Worker [name] of the master at [master], polling [queues] (comma
  /// separated) with [options].
  const HorizonWorkerStart({
    required this.factory,
    required this.name,
    required this.queues,
    required this.master,
    required this.heartbeat,
    this.coordinator,
    this.connection,
    this.tries,
    this.backoffSeconds,
    this.timeout,
    this.sleep = const Duration(seconds: 3),
    this.maxJobs,
    this.maxTime,
    this.idleTransactionTimeout,
  });

  /// Builds the worker's application (`createApp`).
  final ApplicationFactory factory;

  /// The worker's name, also its isolate's debug name.
  final String name;

  /// The queues it starts on, comma separated.
  final String queues;

  /// Where it sends its port, then [WorkerReport]s.
  final SendPort master;

  /// How often it sends a [Heartbeat] (wall clock).
  final Duration heartbeat;

  /// The process's coordinator, shared with the HTTP workers.
  final SendPort? coordinator;

  /// The queue connection; the default one when null.
  final String? connection;

  /// Overrides the jobs' tries.
  final int? tries;

  /// Overrides the jobs' backoff, in seconds.
  final List<int>? backoffSeconds;

  /// Overrides the jobs' timeout.
  final Duration? timeout;

  /// The wait of an idle worker between polls.
  final Duration sleep;

  /// The worker exits after this many jobs, for a fresh one.
  final int? maxJobs;

  /// The worker exits after this long, for a fresh one.
  final Duration? maxTime;

  /// `DB_IDLE_TRANSACTION_TIMEOUT` for the worker's application, set before
  /// it boots (`HorizonConfig.workerIdleTransactionTimeout`); null leaves
  /// the environment's.
  final Duration? idleTransactionTimeout;
}

/// The entry of a Horizon worker isolate: boots its own application, runs
/// a [QueueWorker] on the queues the master assigns, reports a [Heartbeat]
/// with the job it is running, and obeys [Assign], [Pause], [Resume] and
/// [Stop]. Ends with [Exited] (an isolate killed or crashed sends nothing).
Future<void> horizonWorkerMain(HorizonWorkerStart start) async {
  final inbox = ReceivePort();
  // By name: workers may answer in any order.
  start.master.send(<Object>[start.name, inbox.sendPort]);
  Application? app;
  Timer? beat;
  var code = 0;
  try {
    app = start.factory();
    if (start.idleTransactionTimeout case final idle?) {
      app.overrideEnv({'DB_IDLE_TRANSACTION_TIMEOUT': '${idle.inSeconds}'});
    }
    if (start.coordinator case final port?) {
      app.coordinator = RemoteCoordinatorChannel(port);
    }
    final booted = app;
    await booted.boot();
    final database = booted.container.make<DatabaseManager>();
    String sessions() => encodeSessions(database.openSessions());
    final worker = QueueWorker(
      booted.container.make<QueueManager>(),
      logger: booted.logger,
    )..reassign(Assign(start.queues).list);

    // The job running now, from the worker's own lifecycle events.
    String? jobId;
    String? jobUuid;
    String? queue;
    int? startedAt;
    void clear() => jobId = jobUuid = queue = startedAt = null;
    void report() => start.master.send(
      Heartbeat(
        start.name,
        processed: worker.processed,
        jobId: jobId,
        jobUuid: jobUuid,
        queue: queue,
        jobStartedAtMs: startedAt,
        sessions: sessions(),
      ),
    );
    // The recorder: every finished job goes to the Horizon store in the
    // coordinator, without waiting (a store that fails never holds a job).
    final store = booted.container.make<CoordinatorChannel>();
    final running = <String, (String, List<String>)>{};
    void record(RecordedJob job) => unawaited(
      store
          .call(HorizonService.serviceName, 'record', {
            'job': jsonEncode(job.toJson()),
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
    booted.container.make<EventDispatcher>()
      ..listen<JobProcessing>((e) {
        jobId = '${e.jobId}';
        jobUuid = e.uuid;
        queue = e.queue;
        startedAt = DateTime.now().millisecondsSinceEpoch;
        if (e.uuid case final String uuid) {
          running[uuid] = (e.displayName ?? e.jobName, e.tags);
        }
        // At once: a job that blocks the event loop sends nothing after.
        report();
      })
      ..listen<JobProcessed>((e) {
        clear();
        final (name, tags) =
            running.remove(e.uuid) ?? (e.jobName, const <String>[]);
        record(
          RecordedJob(
            uuid: e.uuid ?? '${e.jobId}',
            name: name,
            queue: e.queue,
            status: 'completed',
            at: Clock.now().millisecondsSinceEpoch,
            tags: tags,
            durationMs: e.duration.inMilliseconds,
            worker: start.name,
          ),
        );
      })
      ..listen<JobFailed>((e) {
        clear();
        final (name, tags) =
            running.remove(e.uuid) ?? (e.jobName, const <String>[]);
        record(
          RecordedJob(
            uuid: e.uuid ?? '${e.jobId}',
            name: name,
            queue: e.queue,
            status: 'failed',
            at: Clock.now().millisecondsSinceEpoch,
            tags: tags,
            worker: start.name,
            error: '${e.error}'.split('\n').first,
          ),
        );
      })
      ..listen<JobExceptionOccurred>((_) => clear());
    // A wall-clock timer: a frozen test clock must not stop it.
    beat = Timer.periodic(start.heartbeat, (_) => report());

    inbox.listen((message) {
      switch (message) {
        case final Assign assign:
          worker.reassign(assign.list);
        case Pause():
          worker.pause();
        case Resume():
          worker.resume();
        case Stop():
          worker.stop();
      }
    });
    start.master.send(Ready(start.name, sessions: sessions()));
    report();
    code = await booted.container.runScoped<int>(
      'job',
      (_) => worker.run(
        WorkerOptions(
          connection: start.connection,
          queues: worker.queues,
          tries: start.tries,
          backoff: start.backoffSeconds == null
              ? null
              : [for (final s in start.backoffSeconds!) Duration(seconds: s)],
          timeout: start.timeout,
          sleep: start.sleep,
          maxJobs: start.maxJobs,
          maxTime: start.maxTime,
        ),
      ),
      onUncaughtError: (error, stackTrace) => booted.logger.error(
        'Uncaught asynchronous error in Horizon worker ${start.name}',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    // The last word before Exited: what it processed in all.
    report();
  } catch (error, stackTrace) {
    code = 70; // EX_SOFTWARE: it could not run.
    try {
      app?.logger.error(
        'Horizon worker ${start.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
    } catch (_) {
      stderr.writeln('Horizon worker ${start.name} failed: $error');
    }
  } finally {
    beat?.cancel();
    inbox.close();
    try {
      await app?.shutdown();
    } catch (_) {
      // Nothing more to release.
    }
  }
  Isolate.exit(start.master, Exited(start.name, code));
}
