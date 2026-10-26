import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ConnectionConfig.fromUrl', () {
    test('PostgreSQL with credentials, port and options', () {
      final c = ConnectionConfig.fromUrl(
        'postgresql://shop:s%40cret%3A1@db.internal:6432/shop?sslmode=require&pool=4',
      );
      expect(c.driver, 'pgsql');
      expect((c.host, c.port, c.database), ('db.internal', 6432, 'shop'));
      expect((c.username, c.password), ('shop', 's@cret:1'));
      expect(c.options['sslmode'], 'require');
      expect(c.options['pool'], 4);
    });

    test('MySQL and MariaDB defaults', () {
      final my = ConnectionConfig.fromUrl('mysql://root@localhost/app');
      expect((my.driver, my.port, my.password), ('mysql', 3306, null));
      expect(my.options['charset'], 'utf8mb4');
      expect(ConnectionConfig.fromUrl('mariadb://h/app').driver, 'mariadb');
    });

    test('SQLite paths', () {
      expect(
        ConnectionConfig.fromUrl(
          'sqlite:db/app.sqlite',
          basePath: '/srv',
        ).database,
        p.join('/srv', 'db/app.sqlite'),
      );
      expect(ConnectionConfig.fromUrl('sqlite::memory:').database, ':memory:');
      expect(
        ConnectionConfig.fromUrl('sqlite:///var/app.sqlite').database,
        '/var/app.sqlite',
      );
    });

    test('rejects what is not a database URL', () {
      for (final bad in ['oracle://h/db', 'pgsql://h', 'sqlite:', 'nope']) {
        expect(
          () => ConnectionConfig.fromUrl(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  test(
    'withDatabaseConnection adds a connection with its own settings',
    () async {
      final dir = await Directory.systemTemp.createTemp('extra_conn_');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold the file.
        }
      });
      final legacy = p.join(dir.path, 'legacy.sqlite');
      final app = Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'LEGACY_DB_URL': 'sqlite:$legacy',
          })
          .withDatabaseConnection(
            'legacy',
            (env) => ConnectionConfig.fromUrl(env.string('LEGACY_DB_URL')),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final config = app.config.section<DatabaseConfig>();
      expect(config.connections['legacy']!.database, legacy);
      // The built-in connections are still there, and the default unchanged.
      expect(
        config.connections.keys,
        containsAll(['sqlite', 'pgsql', 'legacy']),
      );
      expect(config.defaultConnection, 'sqlite');

      final legacyDb = await DB.manager.executor('legacy');
      await legacyDb.execute('CREATE TABLE orders (id INTEGER PRIMARY KEY)');
      await DB.table('orders', connection: 'legacy').insert({'id': 1});
      expect(await DB.table('orders', connection: 'legacy').count(), 1);
      expect(File(legacy).existsSync(), isTrue);
    },
  );
}
