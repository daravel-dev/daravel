import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Directory base;
  late Application app;

  Future<void> boot(Map<String, String> env) async {
    base = Directory.systemTemp.createTempSync('daravel_legacy_key');
    addTearDown(() => base.deleteSync(recursive: true));
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', ...env})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      await Schema.dropIfExists('legacy_items');
      await DB.statement(
        'CREATE TABLE legacy_items (id BIGINT PRIMARY KEY, name VARCHAR(50))',
      );
    });
  }

  void suite() {
    test('an empty table starts at 1', () async {
      await app.run(() async {
        expect(await LegacyKey.insert('legacy_items', {'name': 'a'}), 1);
        expect(await LegacyKey.insert('legacy_items', {'name': 'b'}), 2);
      });
    });

    test('it follows the highest key, not the row count', () async {
      await app.run(() async {
        await DB.table('legacy_items').insert({'id': 40, 'name': 'x'});
        expect(await LegacyKey.insert('legacy_items', {'name': 'y'}), 41);
      });
    });

    test('next needs a transaction', () async {
      await app.run(() async {
        await expectLater(LegacyKey.next('legacy_items'), throwsStateError);
        final key = await DB.transaction(() async {
          final key = await LegacyKey.next('legacy_items');
          await DB.table('legacy_items').insert({'id': key, 'name': 'a'});
          return key;
        });
        expect(key, 1);
      });
    });

    test('a rollback gives the key back', () async {
      await app.run(() async {
        await expectLater(
          DB.transaction<void>(() async {
            await LegacyKey.insert('legacy_items', {'name': 'a'});
            throw StateError('no');
          }),
          throwsStateError,
        );
        expect(await LegacyKey.insert('legacy_items', {'name': 'b'}), 1);
      });
    });

    test('parallel inserts get distinct keys', () async {
      await app.run(() async {
        await DB.table('legacy_items').insert({'id': 1, 'name': 'first'});
        final keys = await Future.wait([
          for (var i = 0; i < 10; i++)
            LegacyKey.insert('legacy_items', {'name': 'p$i'}),
        ]);
        expect(keys.toSet(), hasLength(10));
        expect(keys.toList()..sort(), [for (var i = 2; i <= 11; i++) i]);
      });
    });

    test('parallel inserts on an empty table', () async {
      await app.run(() async {
        final keys = await Future.wait([
          for (var i = 0; i < 10; i++)
            LegacyKey.insert('legacy_items', {'name': 'p$i'}),
        ]);
        expect(keys.toList()..sort(), [for (var i = 1; i <= 10; i++) i]);
      });
    });

    test('a writer that takes no lock costs a retry, not a failure', () async {
      await app.run(() async {
        // As Laravel would: a key taken between the read and the insert.
        final key = await DB.transaction(() async {
          final taken = await LegacyKey.next('legacy_items');
          await DB.table('legacy_items').insert({'id': taken, 'name': 'a'});
          return LegacyKey.insert('legacy_items', {'name': 'b'});
        });
        expect(key, 2);
      });
    });

    test('a hostile name is refused, not interpolated', () async {
      await app.run(() async {
        await expectLater(
          LegacyKey.insert('legacy_items; DROP TABLE x', const {}),
          throwsA(anything),
        );
      });
    });
  }

  group('sqlite', () {
    setUp(() => boot({'DB_DATABASE': ':memory:'}));
    suite();
  });

  final pg = Platform.environment['DARAVEL_TEST_PG'];
  group('postgres', () {
    setUp(() {
      final uri = Uri.parse(pg!);
      final user = uri.userInfo.split(':');
      return boot({
        'DB_CONNECTION': 'pgsql',
        'DB_HOST': uri.host,
        'DB_PORT': '${uri.port}',
        'DB_DATABASE': uri.path.replaceFirst('/', ''),
        'DB_USERNAME': user.first,
        'DB_PASSWORD': user[1],
        'DB_SSLMODE': 'disable',
      });
    });
    suite();
  }, skip: pg == null ? 'needs DARAVEL_TEST_PG' : false);
}
