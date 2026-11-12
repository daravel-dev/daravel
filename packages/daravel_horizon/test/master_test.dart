import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String _temp = '${Directory.systemTemp.path}${Platform.pathSeparator}';

/// Where the running test's database file is named, for the worker
/// isolates (they build their application from this file's top-level
/// code, so they read it rather than share a variable).
final String _dbMarker = '${_temp}horizon_master_db_$pid.txt';

/// The running test's database: a file of its own per test. A worker the
/// master killed keeps its SQLite handle open while the process lives, and
/// on Windows such a file cannot be deleted; the next test must not need
/// to (one stalled test used to fail every later one in `setUp`).
String get dbPath {
  final marker = File(_dbMarker);
  return marker.existsSync()
      ? marker.readAsStringSync()
      : '${_temp}horizon_master_$pid.sqlite';
}

final String marksPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_marks_$pid.txt';

/// Blocks its isolate's event loop (no heartbeat) on its first attempt.
final class Hang extends Job {
  const Hang(this.label, {this.ms = 0});
  factory Hang.fromJson(Map<String, Object?> json) {
    final label = json['label']! as String;
    if (label == 'stuck-pop' && !File(stuckPath).existsSync()) {
      // Blocks between the pop and the JobProcessing report, once: the
      // master sees an idle worker that stopped answering.
      File(stuckPath).writeAsStringSync('');
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 3)) {}
    }
    return Hang(label, ms: (json['ms'] as num?)?.toInt() ?? 0);
  }
  final String label;
  final int ms;
  @override
  String get jobName => 'hang';
  @override
  int get tries => 3;
  @override
  List<JobMiddleware> get middleware =>
      label == 'released' ? const [_ReleaseFirst()] : const [];
  @override
  Map<String, Object?> toJson() => {'label': label, 'ms': ms};
  @override
  Future<void> handle(JobContext ctx) async {
    if (label == 'cap') {
      // Each execution's start, to check that none overlaps another.
      File(startsPath).writeAsStringSync(
        '${ctx.attempt}@${DateTime.now().millisecondsSinceEpoch}'
        '${String.fromCharCode(10)}',
        mode: FileMode.append,
      );
      if (ctx.attempt == 1) {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(milliseconds: 2500)) {}
      }
    }
    if (label == 'boom') {
      // Brings its worker down on every attempt.
      Isolate.current.kill(priority: Isolate.immediate);
      await Completer<void>().future;
    }
    if (label == 'slow' || label == 'over') {
      // Synchronous work on every attempt (a PDF, a big JSON), from the
      // handler's first line: 5 s, or 6 s for one past its timeout.
      final watch = Stopwatch()..start();
      final length = Duration(seconds: label == 'slow' ? 5 : 6);
      while (watch.elapsed < length) {}
    }
    if (label == 'hang' && ctx.attempt == 1) {
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {}
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    File(marksPath).writeAsStringSync(
      '${ctx.queue}:$label:${ctx.attempt}\n',
      mode: FileMode.append,
    );
  }
}

final String stuckPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_stuck_$pid';
final String startsPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_starts_$pid';

Application masterApp() => _masterApp('90s');

/// Workers whose queue hands a reserved job to another after 3 s.
Application shortRetryApp() => _masterApp('3s');

Application _masterApp(String retryAfter) =>
    Application.configure(basePath: _basePath())
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': dbPath,
          'QUEUE_CONNECTION': 'database',
          'QUEUE_RETRY_AFTER': retryAfter,
          'CACHE_STORE': 'file',
        })
        .withLogLevel(LogLevel.error)
        .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
        .withJobs([JobDefinition('hang', Hang.fromJson)])
        .create();

/// The marks the jobs wrote. Several worker isolates append to one file at
/// once, and on Windows some appends are lost: check what a mark says, never
/// how many there are.
List<String> marks() =>
    File(marksPath).existsSync() ? File(marksPath).readAsLinesSync() : const [];

Future<void> until(
  bool Function() done,
  String what, {
  int seconds = 30,
  Future<String> Function()? diagnose,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      final diagnosis = diagnose == null ? '' : '\n${await diagnose()}';
      fail('timed out waiting for $what$diagnosis');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Application app;
  final events = <(String, Map<String, Object?>)>[];

  // What the master logged at warning and above: shown when a wait times
  // out (it is quiet otherwise).
  final masterLog = StringBuffer();

  var tests = 0;
  setUp(() async {
    events.clear();
    masterLog.clear();
    File(_dbMarker)
        .writeAsStringSync('${_temp}horizon_master_${pid}_${++tests}.sqlite');
    for (final path in [dbPath, marksPath, stuckPath, startsPath]) {
      if (File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
    app = masterApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() async {
    await app.shutdown();
    // Best effort: a killed worker may still hold it (see dbPath).
    try {
      File(dbPath).deleteSync();
    } on FileSystemException {
      // Left for the temporary directory's own cleanup.
    }
  });
  tearDownAll(() {
    try {
      File(_dbMarker).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  });

  // The process's coordinator with Horizon's store, shared with the
  // workers (as `withCoordinatorService` registers it).
  late Coordinator coordinator;
  setUp(
    () => coordinator = createStandardCoordinator()..register(HorizonService()),
  );
  tearDown(() => coordinator.close());

  HorizonMaster master(
    SupervisorPlan plan, {
    Duration heartbeat = const Duration(milliseconds: 100),
    Duration killGrace = const Duration(seconds: 10),
    ApplicationFactory factory = masterApp,
    Application? driverApp,
  }) => HorizonMaster(
    factory,
    HorizonConfig(
      plans: [plan],
      heartbeat: heartbeat,
      killGrace: killGrace,
      // A short target wait, so a backlog of 20 ms jobs needs workers.
      waits: const {'database:a': Duration(seconds: 1)},
    ),
    driver: (connection) => (driverApp ?? app).container
        .make<QueueManager>()
        .connection(connection),
    logger: Logger(
      minimumLevel: LogLevel.warning,
      out: masterLog,
      err: masterLog,
    ),
    coordinator: coordinator.listen(),
    store: LocalCoordinatorChannel(coordinator),
    failedJobs: app.container.make<QueueManager>().processor.failedJobs,
    onEvent: (event, data) => events.add((event, data)),
    crashDelay: (_) => const Duration(milliseconds: 50),
  );

  /// What a timed-out wait shows: [extra], the queue's rows (waiting and
  /// reserved), failed jobs, each worker of [plan], the master's warnings
  /// and the last 30 events.
  Future<String> diagnosis(
    HorizonMaster m,
    String plan,
    Map<String, Object?> extra,
  ) async {
    final lines = <String>[
      for (final e in extra.entries) '${e.key}: ${e.value}',
    ];
    try {
      await app.run(() async {
        final rows = await DB.table('jobs').get();
        final reserved = rows.where((r) => r['reserved_at'] != null).toList();
        lines
          ..add('jobs rows: ${rows.length}, reserved: ${reserved.length}')
          ..addAll([
            for (final r in reserved.take(5))
              '  reserved id ${r['id']} attempts ${r['attempts']} '
                  'reserved_at ${r['reserved_at']} available_at ${r['available_at']}',
          ])
          ..add('failed_jobs: ${(await DB.table('failed_jobs').get()).length}');
      });
    } on Object catch (error) {
      lines.add('jobs not readable: $error');
    }
    final now = DateTime.now();
    lines.add('workers of $plan: ${m.workers(plan).length}');
    for (final w in m.workers(plan)) {
      lines.add(
        '  ${w.name} ready ${w.ready} busy ${w.busy} stopping ${w.stopping} '
        'recycling ${w.recycling} queues [${w.queues}] '
        'seen ${now.difference(w.lastSeen).inMilliseconds} ms ago '
        'processed ${w.last?.processed}',
      );
    }
    lines
      ..add('marks: ${marks().length}')
      ..add('master log:\n$masterLog')
      ..add('last events:');
    for (final (event, data) in events.skip(
      events.length > 30 ? events.length - 30 : 0,
    )) {
      lines.add('  $event $data');
    }
    return lines.join('\n');
  }

  test(
    'a backlog scales the pool up, at most balanceMaxShift at a time',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() async {
        for (var i = 0; i < 300; i++) {
          await Queue.push(Hang('j$i', ms: 20), queue: 'a');
        }
      });
      final m = master(
        const SupervisorPlan(
          name: SupervisorName('s'),
          queues: [QueueName('a')],
          maxProcesses: 3,
          balanceMaxShift: 2,
          balanceCooldown: Duration(milliseconds: 300),
          sleep: Duration(milliseconds: 50),
        ),
        // Not about kills: a heartbeat a loaded runner keeps up with (at
        // 100 ms its lease is 400 ms, and healthy workers were killed one
        // after another on a stalled Windows runner)...
        heartbeat: const Duration(milliseconds: 500),
        // ...and a job a killed worker had reserved but not reported yet
        // (the master cannot reclaim it) back within the test, not after
        // the default 90 s.
        factory: shortRetryApp,
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(() => m.workers('s').length == 3, 'three workers');
      // The master tells of a resize once it is done: the pool may list its
      // three workers a moment before (a loaded runner), so wait for it.
      List<(int, int)> ups() => [
        for (final (event, data) in events)
          if (event == 'SupervisorLooped' && data['reason'] == 'scale-up')
            (data['before']! as int, data['after']! as int),
      ];
      await until(
        () => ups().isNotEmpty,
        'the scale-up event',
        diagnose: () => diagnosis(m, 's', const {}),
      );
      expect(ups().first, (1, 3));
      var left = 300;
      var polls = 0;
      final pollErrors = <String>[];
      final poll = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        try {
          left = await app.run(() => Queue.size('a'));
          polls++;
        } on Object catch (error) {
          pollErrors.add('$error');
        }
      });
      addTearDown(poll.cancel);
      await until(
        () => left == 0,
        'an empty queue',
        seconds: 90,
        diagnose: () => diagnosis(m, 's', {
          'left': left,
          'polls': polls,
          'poll errors': pollErrors.take(5).toList(),
        }),
      );
      await m.stop(timeout: const Duration(seconds: 20));
      expect(m.workers('s'), isEmpty);
      // The workers recorded every job in the store, and the master read
      // the rates from it. A worker the master killed (its heartbeats late
      // on a loaded runner) may have lost the record of the job it had just
      // finished, or run a reclaimed job a second time: each kill moves the
      // count by at most one. Without a kill it is exactly 300.
      final service =
          coordinator.service(HorizonService.serviceName)! as HorizonService;
      final kills = events.where((e) => e.$1 == 'WorkerKilled').length;
      final completed = service.stats()['completed']! as int;
      if ((completed - 300).abs() > kills) {
        fail(
          'completed $completed of 300 with $kills kill(s)\n'
          '${await diagnosis(m, 's', {'completed': completed})}',
        );
      }
      expect(service.rates('a')['avg_ms'], greaterThanOrEqualTo(20));
    },
  );

  List<Map<String, Object?>> eventsNamed(String name) => [
    for (final (event, data) in events)
      if (event == name) data,
  ];

  SupervisorPlan plan({Duration? timeout, int? tries}) => SupervisorPlan(
    name: const SupervisorName('s'),
    queues: const [QueueName('a')],
    balance: BalanceStrategy.off,
    maxProcesses: 1,
    timeout: timeout,
    tries: tries,
    sleep: const Duration(milliseconds: 50),
  );

  test(
    'a job blocking its isolate (5 s, heartbeat 1 s, timeout 60 s) finishes '
    'once: no kill, no rerun; the master knew it started, and shows the '
    'worker busy, not lost',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('slow'), queue: 'a'));
      final m = master(
        plan(timeout: const Duration(seconds: 60)),
        heartbeat: const Duration(seconds: 1),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      Map<String, Object?>? worker() {
        final workers =
            (m.status()['supervisors']! as Map<String, Object?>)['s']
                as List<Object?>?;
        return workers == null || workers.isEmpty
            ? null
            : workers.first! as Map<String, Object?>;
      }

      // The job blocks from the first line of handle: the report made when
      // it started (JobProcessing, before the middleware and handle) is
      // all the master hears, and enough.
      await until(
        () => worker()?['silentMs'] != null,
        'the busy worker shown as not reporting',
        diagnose: () => diagnosis(m, 's', {'status': m.status()}),
      );
      expect(worker()!['busy'], isTrue);
      expect(m.workers('s').single.last?.jobReservedAtMs, isNotNull);
      await until(() => marks().contains('a:slow:1'), 'the job done');
      // Time for a wrong kill or a rerun to show.
      await Future<void>.delayed(const Duration(seconds: 3));
      await m.stop(timeout: const Duration(seconds: 20));
      expect(eventsNamed('WorkerKilled'), isEmpty);
      expect(marks(), ['a:slow:1']);
      expect(
        await app.run(() async => (await DB.table('failed_jobs').get()).length),
        0,
      );
    },
  );

  test(
    'a job blocking past its timeout is killed after timeout + killGrace '
    '(reason timeout), reclaimed at once and tried again; not a crash',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('hang'), queue: 'a'));
      final m = master(
        plan(timeout: const Duration(seconds: 2)),
        killGrace: const Duration(seconds: 1),
      );
      final watch = Stopwatch()..start();
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => marks().contains('a:hang:2'),
        'attempt 2 on a new worker',
        diagnose: () => diagnosis(m, 's', const {}),
      );
      // retry_after is 90 s: only the reclaim brings it back this soon.
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
      expect(watch.elapsed, greaterThan(const Duration(seconds: 3)));
      final killed = eventsNamed('WorkerKilled');
      expect(killed.single['reason'], 'timeout');
      expect(killed.single['job'], isNotNull);
      final timedOut = eventsNamed('JobTimedOut').single;
      expect(timedOut['attempt'], 1);
      expect(timedOut['limitSeconds'], 3);
      expect(timedOut['reclaimed'], isTrue);
      expect(eventsNamed('JobQuarantined'), isEmpty);
      expect(m.status()['timedOut'], hasLength(1));
      await m.stop(timeout: const Duration(seconds: 20));
    },
  );

  test(
    'tries 2: each attempt past its timeout is killed and counted once, then '
    'the job fails as after a timeout (failed_jobs, not quarantined)',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('over'), queue: 'a'));
      final m = master(
        plan(timeout: const Duration(seconds: 2), tries: 2),
        killGrace: const Duration(seconds: 1),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      // The table is read between polls (`until` takes a getter).
      var rows = const <Map<String, Object?>>[];
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (rows.isEmpty && DateTime.now().isBefore(deadline)) {
        rows = await app.run(() => DB.table('failed_jobs').get());
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await m.stop(timeout: const Duration(seconds: 20));
      expect(rows, hasLength(1), reason: await diagnosis(m, 's', const {}));
      expect(
        '${rows.single['exception']}',
        contains('attempted too many times'),
      );
      final killed = eventsNamed('WorkerKilled');
      expect(killed.map((k) => k['reason']), ['timeout', 'timeout']);
      expect(eventsNamed('JobTimedOut').map((t) => t['attempt']), [
        1,
        2,
      ], reason: 'each attempt counted once');
      expect(eventsNamed('JobQuarantined'), isEmpty);
      expect(marks(), isEmpty, reason: 'no attempt finished');
      expect(await app.run(() => Queue.size('a')), 0);
    },
  );

  test(
    'a job that leaves without a lifecycle event (unknown name, tries used '
    'up on its pop, released by middleware) leaves the worker idle: no kill '
    'once its limit has passed',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // Each alone: a later job's own events would clear a report left
      // behind and hide it.
      for (final (what, push, handled)
          in <(String, Future<void> Function(), Future<bool> Function())>[
            (
              'an unknown job name',
              () => Queue.push(const _Stranger(), queue: 'a'),
              () async => (await DB.table('failed_jobs').get()).length == 1,
            ),
            (
              'tries used up on its pop',
              () async {
                await Queue.push(const Hang('used-up'), queue: 'a');
                await DB.table('jobs').update({'attempts': 3});
              },
              () async => (await DB.table('failed_jobs').get()).length == 1,
            ),
            (
              'released by middleware, unrun',
              () => Queue.push(const Hang('released'), queue: 'a'),
              () async {
                final row = await DB.table('jobs').first();
                return row != null &&
                    row['reserved_at'] == null &&
                    row['attempts'] == 1;
              },
            ),
          ]) {
        await app.run(() async {
          await DB.table('jobs').delete();
          await DB.table('failed_jobs').delete();
          await push();
        });
        events.clear();
        // A limit of 2 s from the reservation (timeout 1 s + killGrace 1 s).
        final m = master(
          plan(timeout: const Duration(seconds: 1)),
          killGrace: const Duration(seconds: 1),
        );
        await m.start();
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!await app.run(handled) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await app.run(handled), isTrue, reason: what);
        // Past its limit: a report left behind would have the master kill
        // the idle worker now.
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(eventsNamed('WorkerKilled'), isEmpty, reason: what);
        expect(m.workers('s').single.busy, isFalse, reason: what);
        await m.stop(timeout: const Duration(seconds: 20));
      }
      expect(marks(), isEmpty, reason: 'none of them ran');
    },
  );

  test(
    'a worker blocked in a job\'s fromJson is known to run that job (it '
    'reported it at the reservation): killed past its timeout, the job '
    'reclaimed at once, not after retry_after',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('stuck-pop'), queue: 'a'));
      // retry_after is 90 s: only a reclaim brings attempt 2 this soon.
      final m = master(
        plan(timeout: const Duration(seconds: 1)),
        killGrace: const Duration(seconds: 1),
      );
      final watch = Stopwatch()..start();
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => marks().contains('a:stuck-pop:2'),
        'the job done on its second attempt',
        diagnose: () => diagnosis(m, 's', const {}),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
      final killed = eventsNamed('WorkerKilled');
      expect(killed.single['reason'], 'timeout');
      expect(
        killed.single['job'],
        isNotNull,
        reason: 'the worker reported the job when it reserved it',
      );
      expect(eventsNamed('JobTimedOut').single['reclaimed'], isTrue);
      await m.stop(timeout: const Duration(seconds: 20));
    },
  );

  test(
    'retry_after caps the limit: the blocked worker is killed a margin '
    'before it (reason timeout), and its job left to retry_after',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // The master's connection says retry_after 3 s, its workers' 90 s:
      // the master trusts what a worker's driver reports only when both
      // say the same, and otherwise kills by the earlier of the two.
      final short = shortRetryApp();
      await short.boot();
      addTearDown(short.shutdown);
      await app.run(() => Queue.push(const Hang('over'), queue: 'a'));
      final m = master(
        plan(timeout: const Duration(seconds: 60)),
        driverApp: short,
      );
      final watch = Stopwatch()..start();
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => eventsNamed('JobTimedOut').isNotEmpty,
        'the kill before retry_after',
        diagnose: () => diagnosis(m, 's', const {}),
      );
      // The job blocks 6 s; the kill came by the master's 3 s, taken to
      // count whole seconds (a second less), less the margin (1 s): about
      // 1 s after the reservation, not at 60 s + killGrace.
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      expect(eventsNamed('WorkerKilled').first['reason'], 'timeout');
      final timedOut = eventsNamed('JobTimedOut').first;
      expect(timedOut['limitSeconds'], 1);
      expect(
        '$masterLog',
        contains(
          "its workers' queue counts retry_after as 90000 ms, the "
          "master's connection as 3000 ms",
        ),
      );
      expect(timedOut['reclaimed'], isFalse);
      expect(timedOut['leftToRetryAfter'], isTrue);
      await m.stop(timeout: const Duration(seconds: 20));
    },
  );

  test(
    'workers and master on different retry_after: one warning per '
    'supervisor however many jobs are killed; no limit timer after stop',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final short = shortRetryApp();
      await short.boot();
      addTearDown(short.shutdown);
      await app.run(() async {
        await Queue.push(const Hang('over'), queue: 'a');
        await Queue.push(const Hang('over'), queue: 'a');
      });
      final m = master(
        plan(timeout: const Duration(seconds: 60)),
        driverApp: short,
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => eventsNamed('JobTimedOut').length == 2,
        'two kills before retry_after',
        diagnose: () => diagnosis(m, 's', const {}),
      );
      expect(
        "its workers' queue counts retry_after".allMatches('$masterLog'),
        hasLength(1),
      );
      final workers = [...m.workers('s')];
      await m.stop(timeout: const Duration(seconds: 20));
      expect([for (final w in workers) w.limitArmed], everyElement(isFalse));
    },
  );

  test(
    'the same retry_after on both sides: a job that ends before its limit '
    'is not killed, and its timer goes with it',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final short = shortRetryApp();
      await short.boot();
      addTearDown(short.shutdown);
      await app.run(() => Queue.push(const Hang('quick', ms: 200), queue: 'a'));
      final m = master(
        plan(timeout: const Duration(seconds: 60)),
        factory: shortRetryApp,
        driverApp: short,
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(() => marks().contains('a:quick:1'), 'the job ran');
      // Past the end of its reservation (3 s at most): a timer left armed
      // would have fired by now.
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      expect(eventsNamed('WorkerKilled'), isEmpty);
      expect(eventsNamed('JobTimedOut'), isEmpty);
      expect('$masterLog', isNot(contains('retry_after as')));
      expect([for (final w in m.workers('s')) w.limitArmed], [false]);
    },
  );

  test(
    'with two workers and retry_after 3 s, a job killed at the cap runs '
    'exactly twice and never beside itself: no reclaim after the limit',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final short = shortRetryApp();
      await short.boot();
      addTearDown(short.shutdown);
      await app.run(() => Queue.push(const Hang('cap'), queue: 'a'));
      // Workers whose queue hands a reserved job to another after 3 s, as
      // the master's own connection says.
      final m = master(
        SupervisorPlan(
          name: const SupervisorName('s'),
          queues: const [QueueName('a')],
          balance: BalanceStrategy.off,
          minProcesses: 2,
          maxProcesses: 2,
          timeout: const Duration(seconds: 60),
          sleep: const Duration(milliseconds: 50),
        ),
        factory: shortRetryApp,
        driverApp: short,
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => marks().contains('a:cap:2'),
        'attempt 2 after retry_after',
        diagnose: () => diagnosis(m, 's', const {}),
      );
      // Time for a third execution to show, if a reclaim freed attempt 2.
      await Future<void>.delayed(const Duration(seconds: 4));
      await m.stop(timeout: const Duration(seconds: 20));
      final starts = [
        for (final line in File(startsPath).readAsLinesSync())
          (int.parse(line.split('@')[0]), int.parse(line.split('@')[1])),
      ];
      expect(starts.map((s) => s.$1), [1, 2], reason: 'exactly two runs');
      // Attempt 1 ran until its kill, 2 s (the cap) after it started:
      // attempt 2 began after that, so the two never ran side by side. It
      // came from the driver's retry_after, not from a reclaim (below).
      expect(
        starts[1].$2 - starts[0].$2,
        greaterThanOrEqualTo(2000),
        reason: 'attempt 2 started after attempt 1 was killed',
      );
      final timedOut = eventsNamed('JobTimedOut').single;
      expect(timedOut['reclaimed'], isFalse);
      expect(timedOut['leftToRetryAfter'], isTrue);
      expect(marks(), ['a:cap:2']);
    },
  );

  test(
    'a job that brings its worker down twice is quarantined in failed_jobs',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('boom'), queue: 'a'));
      final m = master(
        const SupervisorPlan(
          name: SupervisorName('s'),
          queues: [QueueName('a')],
          balance: BalanceStrategy.off,
          maxProcesses: 1,
          sleep: Duration(milliseconds: 50),
        ),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => events.any((e) => e.$1 == 'JobQuarantined'),
        'the quarantine',
      );
      final failed = await app.run(
        () => App.make<QueueManager>().processor.failedJobs.all(),
      );
      expect(failed, hasLength(1));
      expect(failed.single.exception, contains('JobQuarantinedException'));
      expect(failed.single.queue, 'a');
      expect(await app.run(() => Queue.size('a')), 0);
      final quarantined = events.firstWhere((e) => e.$1 == 'JobQuarantined');
      expect(quarantined.$2['crashes'], 2);
      await m.stop(timeout: const Duration(seconds: 20));
    },
  );

  test(
    'horizon:pause, continue and terminate reach it through the signal store',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final signals = app.container.make<QueueManager>().signalStore;
      final m = HorizonMaster(
        masterApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 100),
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        logger: Logger(minimumLevel: LogLevel.critical),
        signals: signals,
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      // A command from before it started is not its own.
      await HorizonSignals.send(signals, 'horizon', 'terminate');
      await m.start();
      await until(() => m.workers('s').any((w) => w.ready), 'a ready worker');

      await HorizonSignals.send(signals, 'horizon', 'pause');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await app.run(() => Queue.push(const Hang('while-paused'), queue: 'a'));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(marks(), isEmpty);

      await HorizonSignals.send(signals, 'horizon', 'continue');
      await until(() => marks().isNotEmpty, 'the job after continue');

      await HorizonSignals.send(signals, 'horizon', 'terminate');
      await until(() => m.workers('s').isEmpty, 'every worker gone');
    },
  );

  test(
    'past HORIZON_MEMORY_LIMIT workers are replaced one at a time',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final m = HorizonMaster(
        masterApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 2,
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 100),
          memoryLimit: 1, // MB: always past it
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        logger: Logger(minimumLevel: LogLevel.critical),
        onEvent: (event, data) => events.add((event, data)),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      final first = {for (final w in m.workers('s')) w.name};
      await until(
        () => events.where((e) => e.$2['reason'] == 'memory').length >= 2,
        'two recycles',
      );
      await until(
        () => m.workers('s').where((w) => !w.stopping).length == 2,
        'two live workers',
      );
      final now = {for (final w in m.workers('s')) w.name};
      expect(now.difference(first), isNotEmpty, reason: 'fresh workers');
      // Never more than one recycled at a time.
      expect(
        m.workers('s').where((w) => w.recycling).length,
        lessThanOrEqualTo(1),
      );
    },
  );

  test(
    'pauseSupervisor pauses one supervisor only',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final m = HorizonMaster(
        masterApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('one'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
            SupervisorPlan(
              name: SupervisorName('two'),
              queues: [QueueName('b')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 100),
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => [...m.workers('one'), ...m.workers('two')].every((w) => w.ready),
        'ready workers',
      );
      m.pauseSupervisor('one');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await app.run(() async {
        await Queue.push(const Hang('held'), queue: 'a');
        await Queue.push(const Hang('free'), queue: 'b');
      });
      await until(() => marks().contains('b:free:1'), 'the other supervisor');
      expect(marks(), isNot(contains('a:held:1')));
      m.resumeSupervisor('one');
      await until(() => marks().contains('a:held:1'), 'after continue');
    },
  );
}

/// This file's own directory, by name and pid: the master and its worker
/// isolates share it (the file signal store, Horizon's status), and test
/// files running in parallel do not.
String _basePath() => (Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_base_$pid',
)..createSync(recursive: true)).path;

/// Releases the job for an hour without running it (as a rate limit or
/// `WithoutOverlapping` does): a way out with no lifecycle event after
/// `JobProcessing`.
final class _ReleaseFirst implements JobMiddleware {
  const _ReleaseFirst();

  @override
  Future<void> handle(JobContext ctx, Job job, JobNext next) async =>
      ctx.release(const Duration(hours: 1));
}

/// A job the workers' registry does not know: it fails before it runs.
final class _Stranger extends Job {
  const _Stranger();
  @override
  String get jobName => 'stranger';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}
