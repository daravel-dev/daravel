import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  redactionTests();
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

  group('withUrl merges like Laravel 12 ConfigurationUrlParser', () {
    // The base and the expected results come from running Laravel's
    // ConfigurationUrlParser::parseConfiguration on the same input.
    const base = ConnectionConfig(
      driver: 'sqlite',
      database: 'laravel',
      host: '127.0.0.1',
      port: 5432,
      username: 'root',
      password: '',
      options: {'sslmode': 'prefer'},
    );

    Map<String, Object?> parsed(String url) {
      final c = base.withUrl(url);
      return {
        'driver': c.driver,
        'host': c.host,
        'port': c.port,
        'database': c.database,
        'username': c.username,
        'password': c.password,
        ...c.options,
      };
    }

    test('every part given', () {
      expect(
        parsed(
          'postgres://shop:s%40cret@db.internal:6432/shop?sslmode=require',
        ),
        {
          'driver': 'pgsql',
          'host': 'db.internal',
          'port': 6432,
          'database': 'shop',
          'username': 'shop',
          'password': 's@cret',
          'sslmode': 'require',
        },
      );
    });

    test('parts left out keep the base values', () {
      expect(parsed('postgresql://db.internal/shop'), {
        'driver': 'pgsql',
        'host': 'db.internal',
        'port': 5432,
        'database': 'shop',
        'username': 'root',
        'password': '',
        'sslmode': 'prefer',
      });
      expect(parsed('pgsql://user:pass@host'), {
        'driver': 'pgsql',
        'host': 'host',
        'port': 5432,
        'database': 'laravel',
        'username': 'user',
        'password': 'pass',
        'sslmode': 'prefer',
      });
    });

    test('driver aliases and typed query options', () {
      expect(
        parsed('mysql2://user@10.0.0.5/legacy?charset=utf8mb4&strict=true'),
        {
          'driver': 'mysql',
          'host': '10.0.0.5',
          'port': 5432,
          'database': 'legacy',
          'username': 'user',
          'password': '',
          'sslmode': 'prefer',
          'charset': 'utf8mb4',
          'strict': true,
        },
      );
      expect(parsed('mariadb://h:3307/app')['driver'], 'mariadb');
      expect(parsed('mariadb://h:3307/app')['port'], 3307);
    });
  });

  test('DB_URL applies to the connections, as in Laravel 12', () {
    final config = DatabaseConfig.fromEnv(
      Env.fromMap(const {
        'DB_CONNECTION': 'pgsql',
        'DB_URL': 'postgres://app:secret@db.internal:6432/shop?sslmode=require',
        'DB_POOL_SIZE': '4',
      }),
      basePath: '/srv',
    );
    final pgsql = config.connections['pgsql']!;
    expect(
      (pgsql.host, pgsql.port, pgsql.database),
      ('db.internal', 6432, 'shop'),
    );
    expect((pgsql.username, pgsql.password), ('app', 'secret'));
    expect(pgsql.options['sslmode'], 'require');
    // DB_* values the URL does not give stay.
    expect(pgsql.options['pool'], 4);
    // Without DB_URL nothing changes.
    final plain = DatabaseConfig.fromEnv(
      Env.fromMap(const {'DB_CONNECTION': 'pgsql', 'DB_HOST': 'h'}),
      basePath: '/srv',
    );
    expect(plain.connections['pgsql']!.host, 'h');
  });

  test('sharesSqliteFile: a SQLite file under several isolates only', () {
    DatabaseConfig config(Map<String, String> env) =>
        DatabaseConfig.fromEnv(Env.fromMap(env), basePath: '/srv');
    final file = config(const {'DB_DATABASE': 'database/app.sqlite'});
    expect(file.sharesSqliteFile(1), isFalse);
    expect(file.sharesSqliteFile(4), isTrue);
    expect(
      config(const {'DB_DATABASE': ':memory:'}).sharesSqliteFile(4),
      isFalse,
      reason: 'refused outright by serve, not a sharing risk',
    );
    expect(
      config(const {'DB_CONNECTION': 'pgsql'}).sharesSqliteFile(4),
      isFalse,
    );
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

void redactionTests() {
  test('a malformed DB_URL is reported without its password', () {
    for (final url in [
      'pgsql://app:s3cr3t@db.example.test:5432',
      'ftp://app:s3cr3t@db.example.test/app',
    ]) {
      Object? error;
      try {
        ConnectionConfig.fromUrl(url);
      } on FormatException catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: url);
      expect('$error', isNot(contains('s3cr3t')), reason: url);
      expect('$error', contains('app:***@db.example.test'), reason: url);
    }
    expect(
      ConnectionConfig.redactUrl('mysql://u@h/d'),
      'mysql://u@h/d',
      reason: 'nothing to mask',
    );
    expect(
      ConnectionConfig.redactUrl('pgsql://u:p%40ss@h/d'),
      'pgsql://u:***@h/d',
    );
  });

  // DB-1 (Reviewer RSEQ 49): the regex only matched a lower-case scheme
  // without `+` and a password without `@` or `/`, and `withUrl` let
  // `Uri.parse`'s FormatException out, which quotes the whole URL.
  group('a password never reaches a message', () {
    const secret = 'S3cr3tPW';
    const urls = [
      'pgsql://u:$secret@ss@new/db', // `@` in the password
      'pgsql://u:$secret/ss@new/db', // `/`
      'pgsql://u:$secret?x@new/db', // `?`
      'pgsql://u:$secret#x@new/db', // `#`
      'PGSQL://u:$secret@h/db', // upper-case scheme
      'Postgres://u:$secret@h/db',
      'mysql+ssl://u:$secret@h/db', // `+` in the scheme
      'postgres://u:$secret@[::1/db', // malformed host
      'pgsql://:$secret@h/db', // no user
      'pgsql://u:$secret@h/db?application_name=a@b', // `@` in the query
      'pgsql:u:$secret@h/db', // no `//`
    ];

    test('redactUrl masks every shape', () {
      for (final url in urls) {
        final redacted = ConnectionConfig.redactUrl(url);
        expect(redacted, isNot(contains(secret)), reason: url);
        expect(redacted, contains('***'), reason: url);
      }
    });

    test('fromUrl, withUrl and DB_URL errors never quote the password', () {
      const base = ConnectionConfig(
        driver: 'pgsql',
        database: 'd',
        host: 'old',
        password: 'old',
      );
      final parsers = <String, Object? Function(String)>{
        'fromUrl': ConnectionConfig.fromUrl,
        'withUrl': base.withUrl,
        'DB_URL': (url) => DatabaseConfig.fromEnv(
          Env.fromMap({'DB_URL': url}),
          basePath: '/srv',
        ),
      };
      var failures = 0;
      for (final url in urls) {
        for (final MapEntry(key: name, value: parse) in parsers.entries) {
          try {
            parse(url);
          } on Object catch (error) {
            failures++;
            expect(error, isA<FormatException>(), reason: '$name $url');
            expect('$error', isNot(contains(secret)), reason: '$name $url');
          }
        }
      }
      expect(failures, greaterThan(10), reason: 'the malformed shapes fail');
    });
  });

  test(
    'a URL user without a password keeps the configured password, as '
    "Laravel 13's ConfigurationUrlParser (array_filter drops a null pass)",
    () {
      const base = ConnectionConfig(
        driver: 'pgsql',
        database: 'd',
        host: 'old',
        username: 'olduser',
        password: 'OLDPW',
      );
      expect(base.withUrl('pgsql://u@new/db').password, 'OLDPW');
      expect(base.withUrl('pgsql://u:@new/db').password, '');
      expect(base.withUrl('pgsql://new/db').username, 'olduser');
    },
  );
}
