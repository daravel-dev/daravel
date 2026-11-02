import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// Runs only with `DARAVEL_TEST_MYSQL`, on MySQL or MariaDB.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];

  group('LegacyKey', () {
    late Application app;

    setUp(() async {
      final uri = Uri.parse(url!);
      final user = uri.userInfo.split(':');
      final base = Directory.systemTemp.createTempSync('daravel_legacy_key');
      addTearDown(() => base.deleteSync(recursive: true));
      app = Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'mysql',
            'DB_HOST': uri.host,
            'DB_PORT': '${uri.port}',
            'DB_DATABASE': uri.path.replaceFirst('/', ''),
            'DB_USERNAME': user.first,
            'DB_PASSWORD': user[1],
          })
          .withLogLevel(LogLevel.critical)
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      await app.run(() async {
        await Schema.dropIfExists('legacy_items');
        await DB.statement(
          'CREATE TABLE legacy_items (id BIGINT PRIMARY KEY, name VARCHAR(50))',
        );
      });
    });

    Future<void> parallel(int first) => app.run(() async {
      final keys = await Future.wait([
        for (var i = 0; i < 10; i++)
          LegacyKey.insert('legacy_items', {'name': 'p$i'}),
      ]);
      expect(keys.toList()..sort(), [for (var i = 0; i < 10; i++) first + i]);
    });

    test('parallel inserts get distinct keys', () async {
      await app.run(
        () => DB.table('legacy_items').insert({'id': 1, 'name': 'first'}),
      );
      await parallel(2);
    });

    test('parallel inserts on an empty table', () => parallel(1));

    test('next holds its key until the transaction ends', () async {
      await app.run(() async {
        final key = await DB.transaction(() async {
          final key = await LegacyKey.next('legacy_items');
          await DB.table('legacy_items').insert({'id': key, 'name': 'a'});
          return key;
        });
        expect(key, 1);
      });
    });
  }, skip: url == null ? 'needs DARAVEL_TEST_MYSQL' : false);
}
