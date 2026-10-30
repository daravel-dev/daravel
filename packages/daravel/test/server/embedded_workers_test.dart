import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A file database shared by every isolate of this test process.
String databasePath() =>
    p.join(Directory.systemTemp.path, 'daravel_embedded_$pid.sqlite');

final class CreateMarksTable extends Migration {
  const CreateMarksTable();

  @override
  String get name => '2026_10_24_000001_create_marks_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('marks', (table) {
    table.id();
    table.string('label');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('marks');
}

final class RecordMark extends Job {
  const RecordMark(this.label);

  final String label;

  @override
  String get jobName => 'record-mark';

  @override
  Map<String, Object?> toJson() => {'label': label};

  @override
  Future<void> handle(JobContext ctx) async {
    await DB.table('marks').insert({'label': label});
  }
}

/// Writes to the `process` cache store: visible to the server only when
/// the embedded isolate shares its coordinator.
final class MarkProcessCache extends Job {
  const MarkProcessCache();

  @override
  String get jobName => 'mark-process-cache';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) => Cache.store(
    'process',
  ).put('embedded.mark', 'seen by the server', ttl: const Duration(minutes: 5));
}

/// Top-level, so it can be sent to the embedded isolates.
Application embeddedApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': databasePath(),
          'QUEUE_CONNECTION': 'database',
        })
        .withLogLevel(LogLevel.warning)
        .withMigrations(const [CreateJobsTable(), CreateMarksTable()])
        .withJobs([
          JobDefinition(
            'record-mark',
            (json) => RecordMark(json['label']! as String),
          ),
          JobDefinition('mark-process-cache', (_) => const MarkProcessCache()),
        ])
        .withSchedule((schedule) {
          schedule(() => DB.table('marks').insert({'label': 'scheduled'}))
              .everyMinute();
        })
        .create();

/// The coordinator of the application `serveWith` boots in this isolate
/// (single-isolate mode); the embedded isolates get its port.
final Coordinator servedCoordinator = createStandardCoordinator();

/// The last application [servedApp] built in this isolate: in the main
/// isolate, the one `serveWith` serves, so the test can stop it.
Application? servedProbe;

/// Top-level, so it can be sent to the embedded isolates.
Application servedApp() =>
    servedProbe = embeddedApp()
      ..coordinator = LocalCoordinatorChannel(servedCoordinator);

Future<List<String>> labels() async {
  final app = embeddedApp();
  await app.boot();
  try {
    return await app.run(
      () async => [
        for (final row in await DB.table('marks').orderBy('id').get())
          row['label']! as String,
      ],
    );
  } finally {
    await app.shutdown();
  }
}

Future<void> waitFor(bool Function(List<String>) done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done(await labels())) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out; marks: ${await labels()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() async {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${databasePath()}$suffix');
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
    final app = embeddedApp();
    await app.boot();
    await app.run(() => app.container.make<Migrator>().run());
    await app.shutdown();
  });

  test(
    'queue and scheduler isolates run and stop promptly',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final app = embeddedApp();
      await app.boot();
      await app.run(() => Queue.dispatch(const RecordMark('queued')));
      await app.shutdown();

      final embedded = EmbeddedWorkers(
        embeddedApp,
        roles: const [EmbeddedRole.queue, EmbeddedRole.scheduler],
        logger: Logger(minimumLevel: .warning),
      );
      await embedded.start();
      // The scheduler runs the due tasks right away, then sleeps to the next
      // minute; the queue picks up the dispatched job.
      await waitFor(
        (marks) => marks.contains('queued') && marks.contains('scheduled'),
      );

      final stopwatch = Stopwatch()..start();
      await embedded.stop(timeout: const Duration(seconds: 20));
      // The scheduler wakes from its minute sleep; the queue finishes its
      // poll sleep (3 s).
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 15)));
    },
  );

  test(
    'an embedded isolate shares the process cache of the coordinator it '
    'is given',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // The server: one coordinator, its process store read from here.
      final coordinator = createStandardCoordinator();
      final server = embeddedApp()
        ..coordinator = LocalCoordinatorChannel(coordinator);
      await server.boot();
      addTearDown(server.shutdown);
      await server.run(() => Queue.dispatch(const MarkProcessCache()));

      final embedded = EmbeddedWorkers(
        embeddedApp,
        roles: const [EmbeddedRole.queue],
        logger: Logger(minimumLevel: .warning),
        coordinator: coordinator.listen(),
      );
      await embedded.start();
      addTearDown(() => embedded.stop(timeout: const Duration(seconds: 20)));

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Object? seen;
      while (seen == null) {
        seen = await server.run(
          () => Cache.store('process').get<String>('embedded.mark'),
        );
        if (seen == null && DateTime.now().isAfter(deadline)) {
          fail('the job ran on a coordinator of its own');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(seen, 'seen by the server');
    },
  );

  test(
    'serveWith with one isolate closes the coordinator port the embedded '
    'workers used, so the process can exit',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final served = Application.serveWith(
        servedApp,
        isolates: 1,
        port: 0,
        embedQueue: true,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (servedProbe?.engine?.port == null) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the server did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // The embedded queue isolate reaches the server's coordinator through
      // this port while the server runs...
      expect(servedCoordinator.isListening, isTrue);
      await servedProbe!.shutdown();
      expect(await served, 0);
      // ...and nothing keeps it open once the server has stopped.
      expect(servedCoordinator.isListening, isFalse);
    },
  );

  test('serveWith refuses an in-memory database with embedded workers', () {
    Application memoryApp() =>
        Application.configure(basePath: Directory.systemTemp.path)
            .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
            .withLogLevel(LogLevel.warning)
            .create();
    expect(
      Application.serveWith(memoryApp, embedQueue: true),
      throwsA(isA<ConfigException>()),
    );
  });
}
