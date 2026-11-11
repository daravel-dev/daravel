// #156: DB_QUERY_TIMEOUT enforced by the server.
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

void main() {
  group('without a server', () {
    test('the session statement per server', () {
      const second = Duration(milliseconds: 1500);
      expect(
        MySqlDriver.sessionTimeoutStatement(second, version: '8.4.3'),
        'SET SESSION max_execution_time = 1500',
      );
      expect(
        MySqlDriver.sessionTimeoutStatement(
          second,
          version: '11.4.2-MariaDB-ubu2404',
        ),
        'SET SESSION max_statement_time = 1.5',
      );
      expect(
        MySqlDriver.sessionTimeoutStatement(
          second,
          version: null,
          dialect: SqlDialect.mariadb,
        ),
        'SET SESSION max_statement_time = 1.5',
      );
    });

    test('3024 and 1969 are timeouts, and never retried', () {
      expect(MySqlDriver.isTimeoutCode(3024), isTrue);
      expect(MySqlDriver.isTimeoutCode(1969), isTrue);
      expect(MySqlDriver.isTimeoutCode(1205), isFalse);
      final driver = MySqlDriver(host: 'h', database: 'd');
      expect(
        driver.isRetryableError(
          const StatementTimeoutException('x', code: 3024),
        ),
        isFalse,
      );
    });

    test('server mode by default; client from statement_timeout_mode', () {
      ConnectionConfig config(Map<String, Object?> options) =>
          ConnectionConfig(driver: 'mysql', database: 'd', options: options);
      final server = MySqlDriver.fromConfig('mysql', config(const {}));
      expect(server.statementTimeoutMode, StatementTimeoutMode.server);
      expect(server.serverSideTimeouts, isTrue);
      final client = MySqlDriver.fromConfig(
        'mysql',
        config(const {'statement_timeout_mode': 'client'}),
      );
      expect(client.statementTimeoutMode, StatementTimeoutMode.client);
      expect(client.serverSideTimeouts, isFalse);
      final none = MySqlDriver.fromConfig(
        'mysql',
        config(const {'query_timeout': '0'}),
      );
      expect(none.serverSideTimeouts, isFalse, reason: 'no timeout, none set');
    });
  });

  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (url == null || url.isEmpty) {
    test(
      'statement timeouts (skipped: DARAVEL_TEST_MYSQL not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');

  MySqlDriver driver({
    StatementTimeoutMode mode = StatementTimeoutMode.server,
    void Function(String)? onWarning,
    List<String> initCommands = const [],
    String? username,
    String? password,
  }) => MySqlDriver(
    host: uri.host,
    port: uri.hasPort ? uri.port : 3306,
    database: uri.path.replaceFirst('/', ''),
    username: username ?? user.first,
    password:
        password ?? (user.length > 1 ? Uri.decodeComponent(user[1]) : null),
    maxConnections: 1,
    queryTimeout: const Duration(seconds: 1),
    statementTimeoutMode: mode,
    onWarning: onWarning,
    initCommands: initCommands,
  );

  // A SELECT the server stops and reports: SLEEP alone may return 1 when
  // interrupted (MySQL), so it runs per row.
  const slow =
      'SELECT SLEEP(1) FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3) x';

  group('integration', () {
    test('a slow SELECT is stopped by the server within the timeout, and the '
        'connection is used again', () async {
      final db = driver();
      await db.connect();
      addTearDown(db.close);
      final before = (await db.select('SELECT CONNECTION_ID() AS id')).first;
      final watch = Stopwatch()..start();
      await expectLater(
        db.select(slow),
        throwsA(
          isA<StatementTimeoutException>().having(
            (e) => e.code,
            'code',
            anyOf(3024, 1969),
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      final after = (await db.select('SELECT CONNECTION_ID() AS id')).first;
      expect(
        after['id'],
        before['id'],
        reason: 'no second connection, no KILL',
      );
    });

    test('inside a transaction: the timeout rolls back cleanly and the next '
        'transaction runs on the same connection', () async {
      final db = driver();
      await db.connect();
      addTearDown(db.close);
      await db.execute('DROP TABLE IF EXISTS b2_items');
      await db.execute('CREATE TABLE b2_items (id INT PRIMARY KEY)');
      addTearDown(() => db.execute('DROP TABLE IF EXISTS b2_items'));
      final id = (await db.select('SELECT CONNECTION_ID() AS id')).first['id'];
      await expectLater(
        db.transaction<void>((tx) async {
          await tx.execute('INSERT INTO b2_items VALUES (1)');
          await tx.select(slow);
        }),
        throwsA(isA<StatementTimeoutException>()),
      );
      expect(await db.select('SELECT * FROM b2_items'), isEmpty);
      final again = await db.transaction(
        (tx) async => (await tx.select('SELECT CONNECTION_ID() AS id')).first,
      );
      expect(again['id'], id);
    });

    test('client mode keeps the old timeout', () async {
      final db = driver(mode: StatementTimeoutMode.client);
      await db.connect();
      addTearDown(db.close);
      expect(db.serverSideTimeouts, isFalse);
      await expectLater(
        db.select(slow),
        throwsA(isNot(isA<StatementTimeoutException>())),
      );
    });

    test('a server that refuses the variable falls back to the client, '
        'with one warning', () async {
      final warnings = <String>[];
      // A variable the server does not know stands in for one it refuses:
      // both take the same fallback (1193, 1227).
      final db = driver(onWarning: warnings.add);
      await db.connect();
      addTearDown(db.close);
      final version =
          '${(await db.select('SELECT VERSION() AS v')).first['v']}';
      if (version.toLowerCase().contains('mariadb')) {
        markTestSkipped('MariaDB: the version picks its own variable');
        return;
      }
      final refused = MySqlDriver(
        host: uri.host,
        port: uri.hasPort ? uri.port : 3306,
        database: uri.path.replaceFirst('/', ''),
        username: user.first,
        password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
        maxConnections: 1,
        queryTimeout: const Duration(seconds: 1),
        onWarning: warnings.add,
        // MySQL does not know max_statement_time (1193).
        dialect: SqlDialect.mariadb,
      );
      await refused.connect();
      addTearDown(refused.close);
      expect(refused.serverSideTimeouts, isFalse);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('enforced by the client'));
    });
  });
}
