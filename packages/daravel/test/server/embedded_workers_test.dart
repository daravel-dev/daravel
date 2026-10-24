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
        ])
        .withSchedule((schedule) {
          schedule(() => DB.table('marks').insert({'label': 'scheduled'}))
              .everyMinute();
        })
        .create();

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

  test('queue and scheduler isolates run and stop promptly', () async {
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
  });

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
