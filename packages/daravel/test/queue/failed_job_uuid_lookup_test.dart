@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `DatabaseFailedJobProvider.find` and `forget` by a UUID that starts with
/// digits (`123abc00-…`) while a row with the integer id `123` exists: each
/// finds and deletes only the row with that UUID. A row id is looked up
/// only when written as one (`'123'`, never `'0123'`, `'+123'`, `' 123'` or
/// a value past 64 bits). On SQLite always, and on PostgreSQL when
/// `DARAVEL_TEST_PG` is set, e.g.
/// `DARAVEL_TEST_PG=postgres://daravel:secret@127.0.0.1:5432/daravel_test`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG'];
  ConnectionConfig postgres() {
    final uri = Uri.parse(url!);
    final userInfo = uri.userInfo.split(':');
    return ConnectionConfig(
      driver: 'pgsql',
      database: uri.path.replaceFirst('/', ''),
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      username: userInfo.first,
      password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
      options: const {'pool': 2, 'sslmode': 'disable'},
    );
  }

  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('failed_job_uuid_');
  });
  tearDownAll(() => dir.delete(recursive: true));

  for (final (name, connection) in [
    (
      'sqlite',
      () => ConnectionConfig(
        driver: 'sqlite',
        database: p.join(dir.path, 'failed.sqlite'),
      ),
    ),
    if (url != null && url.isNotEmpty) ('pgsql', postgres),
  ]) {
    group(name, () => failedJobLookup(connection));
  }
}

/// The cases, on the connection [connection] builds.
void failedJobLookup(ConnectionConfig Function() connection) {
  // A table of its own, so it never meets another test's `failed_jobs`.
  const table = 'failed_jobs_uuid_lookup';
  const decoyId = 123;
  const decoyUuid = '00000000-0000-4000-8000-000000000123';
  const targetId = 124;
  const targetUuid = '123abc00-0000-4000-8000-000000000124';
  late DatabaseManager db;
  late DatabaseFailedJobProvider provider;

  setUp(() async {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'main',
        connections: {'main': connection()},
      ),
    );
    final schema = SchemaBuilder(await db.executor());
    await schema.dropIfExists(table);
    // The columns of `failed_jobs` (`CreateJobsTable`).
    await schema.create(table, (Blueprint t) {
      t.id();
      t.string('uuid').unique();
      t.text('connection');
      t.text('queue');
      t.longText('payload');
      t.longText('exception');
      t.timestamp('failed_at').useCurrent();
    });
    provider = DatabaseFailedJobProvider(db, table: table);
    final now = DateTime.utc(2026, 11, 18, 12);
    for (final (id, uuid, job) in [
      (decoyId, decoyUuid, 'DecoyJob'),
      (targetId, targetUuid, 'TargetJob'),
    ]) {
      await db.table(table).insert({
        'id': id,
        'uuid': uuid,
        'connection': 'database',
        'queue': 'default',
        'payload': '{"uuid":"$uuid","displayName":"$job"}',
        'exception': 'StateError: $job',
        'failed_at': now,
      });
    }
  });

  tearDown(() async {
    await SchemaBuilder(await db.executor()).dropIfExists(table);
    await db.closeAll();
  });

  Future<List<Object?>> ids() async => [
    for (final row in await db.table(table).orderBy('id').get()) row['id'],
  ];

  test(
    'a digit-led UUID that matches no row finds and deletes nothing',
    () async {
      const missing = '123abc00-0000-4000-8000-000000000999';
      expect(await provider.find(missing), isNull);
      expect(await provider.forget(missing), isFalse);
      expect(await ids(), [decoyId, targetId]);
    },
  );

  test('a digit-led UUID finds and deletes only its own row, never the row '
      'whose id is its leading digits', () async {
    final found = await provider.find(targetUuid);
    expect(found?.id, targetId);
    expect(found?.uuid, targetUuid);
    expect(await provider.forget(targetUuid), isTrue);
    expect(await ids(), [decoyId]);
  });

  test(
    'a value that is not written as a row id is never read as one',
    () async {
      for (final value in [
        '0123',
        '+123',
        ' 123',
        '123 ',
        '-123',
        '123.0',
        '9223372036854775808',
      ]) {
        expect(await provider.find(value), isNull, reason: value);
        expect(await provider.forget(value), isFalse, reason: value);
      }
      expect(await ids(), [decoyId, targetId]);
    },
  );

  test('a row id, as an int or as its text, still finds its row', () async {
    expect((await provider.find(decoyId))?.uuid, decoyUuid);
    expect((await provider.find('$targetId'))?.uuid, targetUuid);
    expect(await provider.forget('$decoyId'), isTrue);
    expect(await ids(), [targetId]);
  });
}
