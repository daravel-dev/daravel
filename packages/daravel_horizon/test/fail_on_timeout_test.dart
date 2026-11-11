import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String _temp = '${Directory.systemTemp.path}${Platform.pathSeparator}';

/// The database of the current test: a top-level initializer runs again in
/// every worker isolate, so the path is kept in a file they all read.
final String _dbMarker = '${_temp}horizon_fot_db_$pid.txt';

String get dbPath {
  final marker = File(_dbMarker);
  return marker.existsSync()
      ? marker.readAsStringSync()
      : '${_temp}horizon_fot_$pid.sqlite';
}

/// What the jobs did, one line each: `start:<label>:<attempt>`,
/// `failed:<label>:<error type>`.
final String logPath = '${_temp}horizon_fot_log_$pid.txt';

List<String> logged() =>
    File(logPath).existsSync() ? File(logPath).readAsLinesSync() : const [];

void log(String line) =>
    File(logPath).writeAsStringSync('$line\n', mode: FileMode.append);

/// Blocks its isolate on attempt 1 (a synchronous loop: the worker's own
/// timer never fires, so only the master's kill ends it); later attempts
/// return at once.
final class Blocks extends Job {
  const Blocks(this.label, {this.failsOnTimeout = false, this.maxTries = 3});

  factory Blocks.fromJson(Map<String, Object?> json) => Blocks(
    json['label']! as String,
    failsOnTimeout: json['fot'] == true,
    maxTries: (json['tries']! as num).toInt(),
  );

  final String label;
  final bool failsOnTimeout;
  final int maxTries;

  @override
  String get jobName => 'blocks';

  @override
  int get tries => maxTries;

  @override
  bool get failOnTimeout => failsOnTimeout;

  @override
  Map<String, Object?> toJson() => {
    'label': label,
    'fot': failsOnTimeout,
    'tries': maxTries,
  };

  @override
  Future<void> handle(JobContext ctx) async {
    log('start:$label:${ctx.attempt}');
    if (label == 'every' || ctx.attempt == 1) {
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {}
    }
  }

  @override
  Future<void> failed(Object error, StackTrace stackTrace) async =>
      log('failed:$label:${error.runtimeType}');
}

Application fotApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': dbPath,
          'QUEUE_CONNECTION': 'database',
          'QUEUE_RETRY_AFTER': '90s',
          'CACHE_STORE': 'file',
        })
        .withLogLevel(LogLevel.error)
        .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
        .withJobs([JobDefinition('blocks', Blocks.fromJson)])
        .create();

Future<void> until(
  FutureOr<bool> Function() done,
  String what, {
  int seconds = 60,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what (log: ${logged()})');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Horizon's master decides, from the payload its killed worker reported,
/// whether a job blocked past its timeout fails, and marks it; the worker
/// that reserves it next fails it without running it (Laravel's timeout
/// handler: tries, maxExceptions, failOnTimeout). The master runs none of
/// the job's code.
void main() {
  late Application app;
  final events = <(String, Map<String, Object?>)>[];
  var tests = 0;

  setUp(() async {
    events.clear();
    File(_dbMarker)
        .writeAsStringSync('${_temp}horizon_fot_${pid}_${++tests}.sqlite');
    for (final path in [dbPath, logPath]) {
      if (File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
    app = fotApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });
  tearDown(() async {
    await app.shutdown();
    try {
      File(dbPath).deleteSync();
    } on FileSystemException {
      // A killed worker may still hold it.
    }
  });
  tearDownAll(() {
    for (final path in [_dbMarker, logPath]) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // Already gone.
      }
    }
  });

  late Coordinator coordinator;
  setUp(
    () => coordinator = createStandardCoordinator()..register(HorizonService()),
  );
  tearDown(() => coordinator.close());

  HorizonMaster master({int? tries}) {
    final queues = app.container.make<QueueManager>();
    return HorizonMaster(
      fotApp,
      HorizonConfig(
        plans: [
          SupervisorPlan(
            name: const SupervisorName('s'),
            queues: const [QueueName('a')],
            balance: BalanceStrategy.off,
            maxProcesses: 1,
            timeout: const Duration(seconds: 2),
            tries: tries,
            sleep: const Duration(milliseconds: 50),
          ),
        ],
        heartbeat: const Duration(milliseconds: 100),
        killGrace: const Duration(seconds: 1),
      ),
      driver: queues.connection,
      logger: Logger(minimumLevel: LogLevel.critical),
      coordinator: coordinator.listen(),
      store: LocalCoordinatorChannel(coordinator),
      failedJobs: queues.processor.failedJobs,
      signals: queues.signalStore,
      failsAfterTimeout: queues.processor.failsAfterTimeout,
      onEvent: (event, data) => events.add((event, data)),
      crashDelay: (_) => const Duration(milliseconds: 50),
    );
  }

  Future<List<Map<String, Object?>>> failedRows() =>
      app.run(() => DB.table('failed_jobs').get());
  Future<int> jobRows() =>
      app.run(() async => (await DB.table('jobs').get()).length);
  List<Map<String, Object?>> timedOut() => [
    for (final (event, data) in events)
      if (event == 'JobTimedOut') data,
  ];

  test('a failOnTimeout job killed past its timeout fails on its next '
      'reservation, without running again: TimeoutExceededException in '
      'failed_jobs, its failed() hook run by a worker', () async {
    await app.run(
      () => Queue.push(const Blocks('fot', failsOnTimeout: true), queue: 'a'),
    );
    final m = master();
    addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
    await m.start();
    await until(
      () async => (await failedRows()).isNotEmpty,
      'the job in failed_jobs',
    );
    final row = (await failedRows()).single;
    expect('${row['exception']}', contains('TimeoutExceededException: '));
    expect('${row['exception']}', contains('Blocks has timed out.'));
    await until(
      () => logged().contains('failed:fot:TimeoutExceededException'),
      'the failed() hook',
    );
    expect(await jobRows(), 0, reason: 'the job left the queue');
    expect(logged().where((l) => l.startsWith('start:')), [
      'start:fot:1',
    ], reason: 'never run again');
    expect(timedOut().single['fate'], 'will fail on next reservation');
    // Removed once the job failed (not when it was read).
    final key = HorizonSignals.timedOutKey('${timedOut().single['job']}');
    await until(
      () async =>
          await app.run(() => Queue.manager.signalStore!.store.get(key)) ==
          null,
      'the mark removed',
    );
    await m.stop(timeout: const Duration(seconds: 20));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a mark fails only a later reservation, and reading it does not '
      'remove it', () async {
    final store = app.container.make<QueueManager>().signalStore!;
    final payload = JobPayload.forJob(const Blocks('m'));
    QueuedJob reserved(int attempts) => QueuedJob(
      id: 1,
      queue: 'a',
      payload: payload,
      attempts: attempts,
      raw: payload.encode(),
    );
    await HorizonSignals.markTimedOut(
      store,
      payload.uuid,
      attempt: 2,
      limit: const Duration(seconds: 3),
      ttl: const Duration(minutes: 1),
    );
    expect(await HorizonSignals.timedOutError(store, reserved(2)), isNull);
    final error = await HorizonSignals.timedOutError(store, reserved(3));
    expect(error?.message, 'Blocks has timed out.');
    expect(error?.duration, const Duration(seconds: 3));
    expect(
      await HorizonSignals.timedOutError(store, reserved(3)),
      isNotNull,
      reason: 'still marked until the worker removes it',
    );
    await HorizonSignals.unmarkTimedOut(store, payload.uuid);
    expect(await HorizonSignals.timedOutError(store, reserved(3)), isNull);
  });

  test('a timeout on the last try fails with TimeoutExceededException, as '
      "Laravel's handler does, not MaxAttemptsExceededException", () async {
    await app.run(() => Queue.push(const Blocks('every'), queue: 'a'));
    final m = master(tries: 2);
    addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
    await m.start();
    await until(
      () async => (await failedRows()).isNotEmpty,
      'the job in failed_jobs',
      seconds: 90,
    );
    final row = (await failedRows()).single;
    expect('${row['exception']}', contains('has timed out.'));
    expect(timedOut().map((t) => t['fate']), [
      'made available again',
      'will fail on next reservation',
    ]);
    expect(logged().where((l) => l.startsWith('start:')), [
      'start:every:1',
      'start:every:2',
    ]);
    await m.stop(timeout: const Duration(seconds: 20));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a job with tries left and no failOnTimeout is made available again '
      'and runs again; nothing is marked', () async {
    await app.run(() => Queue.push(const Blocks('retry'), queue: 'a'));
    final m = master();
    addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
    await m.start();
    await until(() => logged().contains('start:retry:2'), 'attempt 2');
    await until(() async => await jobRows() == 0, 'attempt 2 done');
    expect(timedOut().single['fate'], 'made available again');
    expect(await failedRows(), isEmpty);
    final uuid = '${timedOut().single['job']}';
    expect(
      await app.run(
        () => Queue.manager.signalStore!.store.get(
          HorizonSignals.timedOutKey(uuid),
        ),
      ),
      isNull,
    );
    await m.stop(timeout: const Duration(seconds: 20));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
