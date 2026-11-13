import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Payloads that do not decode, as another release, a broken writer or a
/// corrupted store may leave them: recorded in `failed_jobs`, never lost.
/// Before, one that was not JSON (or was empty) made the provider's `log`
/// throw after the queue had already removed it (the Redis queue does):
/// no trace of the job anywhere.
const _corrupt = [
  '{{{corrupt',
  '',
  '[1,2,3]',
  '123',
  '"text"',
  'null',
  '{"uuid":5}',
  '{"uuid":""}',
  '{"uuid":"kept-uuid","displayName":7}',
];

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Each of [_corrupt] recorded with its own uuid, or a new one.
void _expectRecorded(List<(String payload, String uuid)> recorded) {
  expect([for (final (payload, _) in recorded) payload], _corrupt);
  for (final (payload, uuid) in recorded) {
    if (payload == _corrupt.last) {
      expect(uuid, 'kept-uuid', reason: 'its own uuid');
    } else {
      expect(uuid, matches(_uuidV4), reason: payload);
    }
  }
}

void main() {
  late Directory dir;
  late Application app;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('failed_corrupt_');
    app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': p.join(dir.path, 'db.sqlite'),
          'QUEUE_CONNECTION': 'database',
        })
        .withLogLevel(LogLevel.critical)
        .withMigrations(const [CreateJobsTable()])
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() async {
    await app.shutdown();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file.
    }
  });

  test('the database provider records every payload', () async {
    await app.run(() async {
      final provider = DatabaseFailedJobProvider(
        Container.current.make<DatabaseManager>(),
      );
      for (final payload in _corrupt) {
        await provider.log(
          connection: 'redis',
          queue: 'default',
          payload: payload,
          exception: 'CorruptPayloadException',
        );
      }
      final rows = await DB.table('failed_jobs').orderBy('id').get();
      _expectRecorded([
        for (final row in rows)
          (row['payload']! as String, row['uuid']! as String),
      ]);
    });
  });

  test('the memory provider records every payload', () async {
    final provider = MemoryFailedJobProvider();
    for (final payload in _corrupt) {
      await provider.log(
        connection: 'sync',
        queue: 'default',
        payload: payload,
        exception: 'CorruptPayloadException',
      );
    }
    _expectRecorded([
      for (final job in await provider.all()) (job.payload, job.uuid),
    ]);
  });

  test('the database queue: a Daravel payload that does not decode goes to '
      'failed_jobs through the worker; one that is not a Daravel job '
      "stays for Laravel's workers", () async {
    // Daravel-shaped (a `job` name) but not decodable: the worker records
    // them. Not JSON, or no job name: foreign to Daravel (a Laravel app may
    // share the table), skipped untouched by design.
    const daravel = [
      '{"job":"report","uuid":5}',
      '{"job":"report","uuid":"kept-uuid","maxTries":"many"}',
    ];
    const foreign = ['{{{corrupt', '', '[1,2,3]', '123'];
    await app.run(() async {
      final now = Clock.now().millisecondsSinceEpoch ~/ 1000;
      await DB.table('jobs').insert([
        for (final payload in [...daravel, ...foreign])
          {
            'queue': 'default',
            'payload': payload,
            'attempts': 0,
            'reserved_at': null,
            'available_at': now,
            'created_at': now,
          },
      ]);
      final worker = QueueWorker(Queue.manager);
      for (final payload in daravel) {
        expect(
          await worker.runNextJob(Queue.connection(), const WorkerOptions()),
          isTrue,
          reason: payload,
        );
      }
      expect(
        await worker.runNextJob(Queue.connection(), const WorkerOptions()),
        isFalse,
        reason: 'only foreign rows left',
      );
      final failed = await DB.table('failed_jobs').orderBy('id').get();
      expect([for (final row in failed) row['payload']], daravel);
      expect(failed.first['uuid'], matches(_uuidV4));
      expect(failed.last['uuid'], 'kept-uuid');
      final left = await DB.table('jobs').orderBy('id').get();
      expect([for (final row in left) row['payload']], foreign);
      expect([for (final row in left) row['attempts']], [0, 0, 0, 0]);
    });
  });
}
