import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

final class Note extends Job {
  const Note();
  @override
  String get jobName => 'note';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// `queue:flush --hours` deletes nothing unless the value is a whole number
/// of hours above zero, and `queue:clear` needs `--force` in production as
/// artisan's does (`ConfirmableTrait`); artisan's `queue:flush` has no such
/// guard, and neither has dartisan's.
void main() {
  late Directory dir;
  late String db;

  Application queueApp({String env = 'production'}) =>
      Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': env,
            'DB_DATABASE': db,
            'QUEUE_CONNECTION': 'database',
          })
          .withLogLevel(LogLevel.critical)
          .withMigrations(const [CreateJobsTable()])
          .withJobs([JobDefinition('note', (_) => const Note())])
          .create();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('queue_flush_');
    db = '${dir.path}${Platform.pathSeparator}app.sqlite';
    final app = queueApp();
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      final queue = App.make<QueueManager>();
      await queue.processor.failedJobs.log(
        connection: 'database',
        queue: 'default',
        payload: JobPayload.forJob(const Note(), uuid: 'uuid-a').encode(),
        exception: 'StateError: boom',
      );
      await queue.connection().push(
        JobPayload.forJob(const Note(), uuid: 'uuid-b'),
        queue: 'default',
      );
    });
    await app.shutdown();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run(List<String> args, {String env = 'production'}) =>
      IOOverrides.runZoned(
        () => DartisanRunner(() => queueApp(env: env)).execute(args),
        stdout: () => _Silent(),
        stderr: () => _Silent(),
      );

  /// Failed jobs and pending jobs left.
  Future<(int, int)> counts() async {
    final app = queueApp();
    await app.boot();
    try {
      return await app.run(
        () async => (
          (await App.make<QueueManager>().processor.failedJobs.all()).length,
          await App.make<QueueManager>().connection().size('default'),
        ),
      );
    } finally {
      await app.shutdown();
    }
  }

  for (final hours in ['24h', '-5', '0', '', ' ', '1.5', 'abc']) {
    test('queue:flush --hours="$hours" is a usage error and deletes '
        'nothing', () async {
      expect(await run(['queue:flush', '--hours=$hours']), 64);
      expect(await counts(), (1, 1));
    });
  }

  test('queue:flush --hours=1 keeps a job that failed just now; '
      'without --hours every failed job goes, in production too', () async {
    expect(await run(['queue:flush', '--hours=1']), 0);
    expect(await counts(), (1, 1));
    expect(await run(['queue:flush']), 0);
    expect(await counts(), (0, 1));
  });

  test('queue:clear needs --force in production', () async {
    expect(await run(['queue:clear']), 1);
    expect(await counts(), (1, 1));
    expect(await run(['queue:clear', '--force']), 0);
    expect(await counts(), (1, 0));
  });

  test('queue:clear outside production runs without --force', () async {
    expect(await run(['queue:clear'], env: 'local'), 0);
    expect(await counts(), (1, 0));
  });
}

final class _Silent implements Stdout {
  @override
  void write(Object? object) {}

  @override
  void writeln([Object? object = '']) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
