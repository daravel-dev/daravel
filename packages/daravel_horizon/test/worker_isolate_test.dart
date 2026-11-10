import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

/// Shared by every isolate of this process (top-level, from the pid).
final String dbPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_worker_$pid.sqlite';
final String marksPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_marks_$pid.txt';

final class Mark extends Job {
  const Mark(this.label, {this.ms = 0});
  factory Mark.fromJson(Map<String, Object?> json) =>
      Mark(json['label']! as String, ms: (json['ms'] as num?)?.toInt() ?? 0);
  final String label;
  final int ms;
  @override
  String get jobName => 'mark';
  @override
  Map<String, Object?> toJson() => {'label': label, 'ms': ms};
  @override
  Future<void> handle(JobContext ctx) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    File(marksPath)
        .writeAsStringSync('${ctx.queue}:$label\n', mode: FileMode.append);
  }
}

/// Top-level, so worker isolates can build it.
Application testApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': dbPath,
          'QUEUE_CONNECTION': 'database',
          'CACHE_STORE': 'file',
        })
        .withLogLevel(LogLevel.error)
        .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
        .withJobs([JobDefinition('mark', Mark.fromJson)])
        .create();

List<String> marks() =>
    File(marksPath).existsSync() ? File(marksPath).readAsLinesSync() : const [];

Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Application app;

  setUp(() async {
    for (final path in [dbPath, marksPath]) {
      if (File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
    app = testApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() => app.shutdown());

  test(
    'a worker isolate runs its queues, follows Assign, reports the job '
    'it runs, and exits on Stop',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      await app.run(() async {
        await Queue.push(const Mark('a1'), queue: 'a');
        await Queue.push(const Mark('b1', ms: 600), queue: 'b');
      });
      final reports = ReceivePort();
      final received = <Object?>[];
      final port = Completer<SendPort>();
      reports.listen((m) {
        if (m case [final String _, final SendPort p]) {
          port.complete(p);
        } else {
          received.add(m);
        }
      });
      await Isolate.spawn(
        horizonWorkerMain,
        HorizonWorkerStart(
          factory: testApp,
          name: 'horizon-test-1',
          queues: 'a',
          master: reports.sendPort,
          heartbeat: const Duration(milliseconds: 50),
          sleep: const Duration(milliseconds: 50),
        ),
        debugName: 'horizon-test-1',
      );
      final worker = await port.future.timeout(const Duration(seconds: 10));
      await until(() => received.whereType<Ready>().isNotEmpty, 'Ready');
      await until(() => marks().contains('a:a1'), 'the job on a');
      expect(marks(), isNot(contains('b:b1')), reason: 'not assigned yet');

      worker.send(const Assign('b'));
      await until(
        () => received.whereType<Heartbeat>().any((h) => h.queue == 'b'),
        'a heartbeat with the running job',
      );
      final running = received.whereType<Heartbeat>().firstWhere(
        (h) => h.queue == 'b',
      );
      expect(running.jobUuid, isNotEmpty);
      expect(running.jobId, isNotNull);
      expect(running.jobStartedAtMs, isNotNull);
      await until(() => marks().contains('b:b1'), 'the job on b');

      worker.send(const Stop());
      await until(() => received.whereType<Exited>().isNotEmpty, 'Exited');
      final exited = received.whereType<Exited>().single;
      expect((exited.worker, exited.code), ('horizon-test-1', 0));
      expect(received.whereType<Heartbeat>().last.processed, 2);
      reports.close();
    },
  );

  test('HorizonTags.model names a model or a ModelRef by its table', () {
    final ref = ModelRef<Thing>(() => Thing.definition, 42);
    expect(HorizonTags.model(ref), 'Thing:42');
    expect(() => HorizonTags.model('x'), throwsArgumentError);
  });
}

final class Thing extends Model {
  static final ModelDefinition<Thing> definition = ModelDefinition<Thing>(
    table: 'things',
    factory: Thing.new,
  );
  @override
  ModelDefinition<Thing> get modelDefinition => Thing.definition;
}
