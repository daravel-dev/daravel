import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String dbPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_setup_$pid.sqlite';
final String marksPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_setup_marks_$pid.txt';

final class Note extends Job {
  const Note(this.label);
  factory Note.fromJson(Map<String, Object?> json) =>
      Note(json['label']! as String);
  final String label;
  @override
  String get jobName => 'note';
  @override
  Map<String, Object?> toJson() => {'label': label};
  @override
  Future<void> handle(JobContext ctx) async =>
      File(marksPath).writeAsStringSync('$label\n', mode: FileMode.append);
}

/// The application, as `bootstrap/app.dart` would write it.
Application horizonApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': dbPath,
          'QUEUE_CONNECTION': 'database',
          'CACHE_STORE': 'file',
          'HORIZON_HEARTBEAT_MS': '100',
          'HORIZON_ALLOW_SQLITE': 'true',
        })
        .withLogLevel(LogLevel.error)
        .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
        .withJobs([JobDefinition('note', Note.fromJson)])
        .withHorizon(
          createApp: horizonApp,
          plans: const [
            SupervisorPlan(
              name: SupervisorName('supervisor-1'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
          ],
        )
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
    app = horizonApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() => app.shutdown());

  test(
    'withHorizon registers the config, its store and the embedded worker',
    () {
      expect(
        app.config.section<HorizonConfig>().plans.single.name.value,
        'supervisor-1',
      );
      expect(app.embeddedWorkerNames, contains('horizon'));
      final channel = app.container.make<CoordinatorChannel>();
      final coordinator = (channel as LocalCoordinatorChannel).coordinator;
      expect(coordinator.service(HorizonService.serviceName), isNotNull);
    },
  );

  test(
    'serve --embed-worker=horizon runs the supervisors, pauses and '
    'continues on command, and stops with the server',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final coordinator = createStandardCoordinator()
        ..register(HorizonService());
      addTearDown(coordinator.close);
      final embedded = EmbeddedWorkers(
        horizonApp,
        roles: const [],
        custom: const ['horizon'],
        logger: Logger(minimumLevel: LogLevel.critical),
        coordinator: coordinator.listen(),
      );
      await embedded.start();
      addTearDown(() => embedded.stop(timeout: const Duration(seconds: 20)));

      await app.run(() async {
        for (var i = 0; i < 3; i++) {
          await Queue.push(Note('n$i'), queue: 'a');
        }
      });
      await until(() => marks().length == 3, 'the jobs');

      await embedded.send('horizon', 'pause');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await app.run(() => Queue.push(const Note('paused'), queue: 'a'));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(marks(), isNot(contains('paused')));
      await embedded.send('horizon', 'continue');
      await until(() => marks().contains('paused'), 'the job after continue');

      final recent = jsonDecode(
        (await LocalCoordinatorChannel(coordinator).call(
              HorizonService.serviceName,
              'recent',
              {'status': 'completed'},
            ))!
            as String,
      ) as List<Object?>;
      expect(recent, hasLength(4), reason: 'recorded in the server store');
      await embedded.stop(timeout: const Duration(seconds: 20));
    },
  );
}
