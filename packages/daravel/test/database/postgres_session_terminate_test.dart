@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Runs only when `DARAVEL_TEST_PG` is set, as `postgres_integration_test`:
/// `DARAVEL_TEST_PG=postgres://daravel:secret@127.0.0.1:5432/daravel_test`.
///
/// A transaction left open by a killed isolate is simulated by one that
/// never finishes: its connection stays open, idle inside the transaction,
/// holding the row lock, as `pg_stat_activity` showed for a worker isolate
/// killed with `Isolate.kill`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG'];
  if (url == null || url.isEmpty) {
    test(
      'postgres session termination (skipped: DARAVEL_TEST_PG not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');

  PostgresDriver driver({int pool = 2, Duration? idle}) {
    final driver = PostgresDriver(
      host: uri.host,
      port: uri.port,
      database: uri.path.replaceFirst('/', ''),
      username: user.first,
      password: user.length > 1 ? user[1] : null,
      maxConnections: pool,
      idleTransactionTimeout: idle,
    );
    addTearDown(driver.close);
    return driver;
  }

  /// Starts a transaction on [holder] that locks row 1 and waits for
  /// [release]; completes the returned record's `locked` once it holds it.
  ({Future<void> done, Future<void> locked}) holdLock(
    PostgresDriver holder,
    Future<void> release,
  ) {
    final locked = Completer<void>();
    final done = holder.transaction((tx) async {
      await tx.execute('UPDATE session_rows SET v = 1 WHERE id = 1');
      locked.complete();
      await release;
    });
    // Ends with an error once the server ended the session.
    unawaited(done.then((_) {}, onError: (Object _) {}));
    return (done: done, locked: locked.future);
  }

  setUp(() async {
    final setup = driver();
    await setup.connect();
    await setup.execute('DROP TABLE IF EXISTS session_rows');
    await setup.execute(
      'CREATE TABLE session_rows (id integer PRIMARY KEY, v integer)',
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
    final watch = Stopwatch()..start();
    expect(await other.terminateSession(ids.single), isTrue);
    await other
        .execute('UPDATE session_rows SET v = 2 WHERE id = 1')
        .timeout(const Duration(seconds: 5));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

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
      expect(await other.terminateSession('not-a-pid'), isFalse);
    },
  );

  test('idleTransactionTimeout makes the server end such a session', () async {
    final holder = driver(pool: 1, idle: const Duration(seconds: 1));
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

  test(
    'DatabaseManager.openSessions lists the open connection\'s sessions',
    () async {
      final db = DatabaseManager(
        DatabaseConfig(
          defaultConnection: 'pgsql',
          connections: {
            'pgsql': ConnectionConfig(
              driver: 'pgsql',
              database: uri.path.replaceFirst('/', ''),
              host: uri.host,
              port: uri.port,
              username: user.first,
              password: user.length > 1 ? user[1] : null,
              options: const {'pool': 1, 'sslmode': 'disable'},
            ),
          },
        ),
      );
      addTearDown(db.closeAll);
      expect(db.openSessions(), isEmpty, reason: 'not connected yet');
      final pgsql = await db.connection();
      final pid = (await pgsql.select('SELECT pg_backend_pid() AS pid'))
          .single['pid'];
      expect(db.openSessions(), {
        'pgsql': ['$pid'],
      });
    },
  );
}
