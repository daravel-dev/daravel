@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// Runs only when `DARAVEL_TEST_MYSQL` is set, as `mysql_integration_test`.
///
/// A transaction left open by a killed isolate is simulated by one that
/// never finishes: its connection stays open inside the transaction,
/// holding the row lock.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (url == null || url.isEmpty) {
    test(
      'mysql session termination (skipped: DARAVEL_TEST_MYSQL not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');

  MySqlDriver driver({
    int pool = 2,
    Duration? idle,
    SqlDialect dialect = SqlDialect.mysql,
  }) {
    final driver = MySqlDriver(
      host: uri.host,
      port: uri.hasPort ? uri.port : 3306,
      database: uri.path.replaceFirst('/', ''),
      username: user.first,
      password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
      maxConnections: pool,
      idleTransactionTimeout: idle,
      dialect: dialect,
    );
    addTearDown(driver.close);
    return driver;
  }

  ({Future<void> done, Future<void> locked}) holdLock(
    MySqlDriver holder,
    Future<void> release,
  ) {
    final locked = Completer<void>();
    final done = holder.transaction((tx) async {
      await tx.execute('UPDATE session_rows SET v = 1 WHERE id = 1');
      locked.complete();
      await release;
    });
    unawaited(done.then((_) {}, onError: (Object _) {}));
    return (done: done, locked: locked.future);
  }

  late bool mariadb;

  setUp(() async {
    final setup = driver();
    await setup.connect();
    final version = await setup.select('SELECT VERSION() AS v');
    mariadb = '${version.single['v']}'.contains('MariaDB');
    await setup.execute('DROP TABLE IF EXISTS session_rows');
    await setup.execute(
      'CREATE TABLE session_rows (id int PRIMARY KEY, v int) ENGINE=InnoDB',
    );
    await setup.execute('INSERT INTO session_rows (id, v) VALUES (1, 0)');
  });

  test('terminateSession ends a session left inside a transaction: its lock '
      'goes at once', () async {
    final holder = driver(pool: 1);
    final other = driver();
    await holder.connect();
    await other.connect();
    final release = Completer<void>();
    final held = holdLock(holder, release.future);
    await held.locked;

    final ids = holder.sessionIds();
    expect(ids, hasLength(1));
    expect(await other.terminateSession(ids.single), isTrue);
    await other
        .execute('UPDATE session_rows SET v = 2 WHERE id = 1')
        .timeout(const Duration(seconds: 5));

    release.complete();
    await expectLater(held.done, throwsA(anything));
    final rows = await other.select('SELECT v FROM session_rows WHERE id = 1');
    expect(rows.single['v'], 2, reason: 'the held update was rolled back');
  });

  test(
    'terminateSession answers false for an unknown or malformed id',
    () async {
      final other = driver();
      await other.connect();
      expect(await other.terminateSession('2147483000'), isFalse);
      expect(await other.terminateSession('not-an-id'), isFalse);
    },
  );

  for (final dialect in [SqlDialect.mariadb, SqlDialect.mysql]) {
    test('MariaDB: idleTransactionTimeout makes the server end such a session '
        '(${dialect.name} connection)', () async {
      if (!mariadb) {
        markTestSkipped('MySQL has no idle_transaction_timeout');
        return;
      }
      final holder = driver(
        pool: 1,
        idle: const Duration(seconds: 1),
        dialect: dialect,
      );
      final other = driver();
      await holder.connect();
      await other.connect();
      final release = Completer<void>();
      final held = holdLock(holder, release.future);
      await held.locked;

      final watch = Stopwatch()..start();
      await other
          .execute('UPDATE session_rows SET v = 3 WHERE id = 1')
          .timeout(const Duration(seconds: 10));
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 500)));
      release.complete();
      await expectLater(held.done, throwsA(anything));
    });
  }
}
