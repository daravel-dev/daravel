@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `DatabaseFailedJobProvider.find` and `forget` by a UUID that starts with
/// digits (`123abc00-…`) while a row with the integer id `123` exists: each
/// finds and deletes only the row with that UUID. Runs against PostgreSQL
/// when `DARAVEL_TEST_PG` is set, e.g.
/// `DARAVEL_TEST_PG=postgres://daravel:secret@127.0.0.1:5432/daravel_test`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG'];
  if (url == null || url.isEmpty) {
    test(
      'failed job lookup by a digit-led UUID (DARAVEL_TEST_PG not set)',
      () {},
      skip: true,
    );
    return;
  }

  // A table of its own, so it never meets another test's `failed_jobs`.
  const table = 'failed_jobs_uuid_lookup';
  final uri = Uri.parse(url);
  final userInfo = uri.userInfo.split(':');
  late DatabaseManager db;
  late DatabaseFailedJobProvider provider;

  setUp(() async {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'pgsql',
        connections: {
          'pgsql': ConnectionConfig(
            driver: 'pgsql',
            database: uri.path.replaceFirst('/', ''),
            host: uri.host,
            port: uri.hasPort ? uri.port : 5432,
            username: userInfo.first,
            password: userInfo.length > 1
                ? Uri.decodeComponent(userInfo[1])
                : null,
            options: const {'pool': 2, 'sslmode': 'disable'},
          ),
        },
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
  });

  tearDown(() async {
    await SchemaBuilder(await db.executor()).dropIfExists(table);
    await db.closeAll();
  });

  test('find and forget by a digit-led UUID touch only the row with that '
      'UUID, never the row whose id is its leading digits', () async {
    const decoyId = 123;
    const decoyUuid = '00000000-0000-4000-8000-000000000123';
    const targetId = 124;
    const targetUuid = '123abc00-0000-4000-8000-000000000124';
    const missingUuid = '123abc00-0000-4000-8000-000000000999';

    final now = DateTime.utc(2026, 11, 18, 12);
    for (final (id, uuid, name) in [
      (decoyId, decoyUuid, 'DecoyJob'),
      (targetId, targetUuid, 'TargetJob'),
    ]) {
      await db.table(table).insert({
        'id': id,
        'uuid': uuid,
        'connection': 'database',
        'queue': 'default',
        'payload': '{"uuid":"$uuid","displayName":"$name"}',
        'exception': 'StateError: $name',
        'failed_at': now,
      });
    }

    // A UUID that matches no row: nothing found, nothing deleted.
    expect(await provider.find(missingUuid), isNull);
    expect(await provider.forget(missingUuid), isFalse);
    expect(await db.table(table).count(), 2);

    // The UUID of a row: that row, and only it is deleted.
    final found = await provider.find(targetUuid);
    expect(found, isNotNull);
    expect(found!.id, targetId);
    expect(found.uuid, targetUuid);
    expect(await provider.forget(targetUuid), isTrue);

    final remaining = await db.table(table).get();
    expect(remaining, hasLength(1));
    expect(remaining.single['id'], decoyId);
    expect(remaining.single['uuid'], decoyUuid);
  });
}
