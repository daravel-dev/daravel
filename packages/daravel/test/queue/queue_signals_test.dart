import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `dartisan queue:restart` and `queue:pause` run in a process of their
/// own: two applications with their own coordinators are two processes
/// (a `queue:work` and the command), sharing only the disk and database.
void main() {
  late Directory dir;
  final apps = <Application>[];

  Future<Application> process([Map<String, String> env = const {}]) async {
    final app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': '${dir.path}/app.sqlite',
          'QUEUE_CONNECTION': 'database',
          ...env,
        })
        .withMigrations(const [CreateJobsTable()])
        .create();
    await app.boot();
    apps.add(app);
    return app;
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_signals_'));

  tearDown(() async {
    for (final app in apps) {
      await app.shutdown();
    }
    apps.clear();
    dir.deleteSync(recursive: true);
  });

  test('queue:restart in another process stops a database worker', () async {
    final worker = await process();
    await worker.run(() => App.make<Migrator>().run());
    final command = await process();

    final run = worker.run(
      () =>
          QueueWorker(Queue.manager)
              .run(const WorkerOptions(sleep: Duration(milliseconds: 20))),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await command.run(() => Queue.manager.restart());
    expect(await run.timeout(const Duration(seconds: 5)), 1);
  });

  test('queue:pause and queue:continue reach another process', () async {
    final worker = await process();
    final command = await process();

    await command.run(() => Queue.manager.pause('default'));
    expect(await worker.run(() => Queue.manager.isPaused('default')), isTrue);
    await command.run(() => Queue.manager.resume('default'));
    expect(await worker.run(() => Queue.manager.isPaused('default')), isFalse);
  });

  test('QUEUE_SIGNAL_STORE chooses where the signals live', () async {
    final app = await process({'QUEUE_SIGNAL_STORE': 'process'});
    await app.run(() => Queue.manager.restart());
    final other = await process({'QUEUE_SIGNAL_STORE': 'process'});
    expect(await other.run(() => Queue.manager.restartRequestedAt()), isNull);
  });

  group('unique-job locks with the database queue', () {
    QueueConfig config(Map<String, String> env) =>
        QueueConfig.fromEnv(Env.fromMap(env));

    Iterable<ConfigIssue> issues(Map<String, String> env) => QueueConfig.check(
      Env.fromMap(env),
      ConfigRepository()..register(config(env)),
    );

    test('live in the database store by default', () {
      expect(
        config({'QUEUE_CONNECTION': 'database'}).uniqueLockStore,
        'database',
      );
      expect(config({'QUEUE_CONNECTION': 'sync'}).uniqueLockStore, 'process');
      expect(issues({'QUEUE_CONNECTION': 'database'}), isEmpty);
    });

    test('in a store of one process, warn at boot', () {
      final found = issues({
        'QUEUE_CONNECTION': 'database',
        'QUEUE_UNIQUE_LOCK_STORE': 'process',
      });
      expect(found.single.level, ConfigIssueLevel.warning);
      expect(found.single.message, contains('queue:work'));
    });
  });
}
