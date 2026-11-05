import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException, sqlite3;
import 'package:test/test.dart';

import 'support/test_databases.dart';

/// Robustness of the database layer (#156): the body's error survives a
/// failing rollback, a driver factory that throws is not cached, SQLite
/// transactions take the write lock up front and retry busy errors, a
/// query that waits on a transaction it is not part of gives up, listeners
/// can be removed, and `closeAll` closes what it can.
void main() {
  group('a failing rollback does not hide the error', () {
    late DatabaseManager db;

    setUp(() async {
      db = sqliteInMemory();
      await db.statement('CREATE TABLE items (name TEXT)');
    });
    tearDown(() => db.closeAll());

    test('a body that ended the transaction itself', () async {
      await expectLater(
        db.transaction(() async {
          // A SQL dump's own COMMIT.
          await db.statement('COMMIT');
          throw StateError('the real error');
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'the real error',
          ),
        ),
      );
      // The connection still works.
      await db.transaction(() => db.table('items').insert({'name': 'next'}));
      expect(await db.table('items').count(), 1);
    });

    test('SQLITE_FULL, which rolls back by itself', () async {
      final pages =
          (await db.select('PRAGMA page_count')).single.values.single! as int;
      await db.statement('PRAGMA max_page_count = $pages');
      final error = await db
          .transaction(() async {
            for (var i = 0; i < 64; i++) {
              await db.table('items').insert({'name': 'x' * 4096});
            }
          })
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<QueryException>());
      final cause = (error! as QueryException).previous;
      expect(cause, isA<SqliteException>());
      // SQLITE_FULL (13), not "cannot rollback - no transaction is active".
      expect((cause as SqliteException).resultCode, 13);
    });

    test('a savepoint whose ROLLBACK TO fails', () async {
      final events = <TransactionEvent>[];
      db.listenTransactions(events.add);
      final outer = Completer<Object?>();
      await expectLater(
        db.transaction(() async {
          await expectLater(
            db.transaction(() async {
              // Ends the transaction and its savepoints.
              await db.statement('COMMIT');
              throw StateError('inner error');
            }),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'inner error',
              ),
            ),
          );
          // The transaction is gone: the outer level must not keep
          // writing in autocommit.
          try {
            await db.table('items').insert({'name': 'outer'});
            outer.complete(null);
          } on Object catch (error) {
            outer.complete(error);
            rethrow;
          }
        }),
        throwsStateError,
      );
      expect(await outer.future, isA<StateError>());
      expect(await db.table('items').count(), 0);
      expect(events.whereType<DbTransactionRolledBack>(), isNotEmpty);
    });
  });

  test('a driver factory that throws is tried again', () async {
    var calls = 0;
    final db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'flaky',
        connections: {
          'flaky': ConnectionConfig(driver: 'flaky', database: ':memory:'),
        },
      ),
      drivers: {
        'flaky': (name, connection) {
          if (++calls == 1) {
            throw StateError('secret not available yet');
          }
          return SqliteDriver(path: ':memory:', name: name);
        },
      },
    );
    addTearDown(db.closeAll);
    await expectLater(db.connection(), throwsStateError);
    expect(await db.select('SELECT 1 AS one'), [
      {'one': 1},
    ]);
    expect(calls, 2);
  });

  group('SQLite locking', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('daravel_lock_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold the WAL files for a moment.
      }
    });

    test('a transaction holds the write lock from its start', () async {
      final path = '${dir.path}/app.sqlite';
      final driver = SqliteDriver(path: path);
      await driver.connect();
      addTearDown(driver.close);
      await driver.execute('CREATE TABLE items (name TEXT)');
      final other = sqlite3.open(path)..execute('PRAGMA busy_timeout = 0');
      addTearDown(other.close);
      await driver.transaction((tx) async {
        // Nothing written yet; another connection still cannot start a
        // write, so this transaction's later write cannot be refused
        // because another one committed first (SQLITE_BUSY_SNAPSHOT).
        await tx.select('SELECT count(*) FROM items');
        expect(
          () => other.execute('BEGIN IMMEDIATE'),
          throwsA(
            isA<SqliteException>().having((e) => e.resultCode, 'code', 5),
          ),
        );
        await tx.execute('INSERT INTO items VALUES (?)', ['kept']);
      });
      expect(other.select('SELECT name FROM items').single['name'], 'kept');
    });

    test('busy and locked errors are retryable', () {
      final driver = SqliteDriver(path: ':memory:');
      SqliteException error(int code) =>
          SqliteException(extendedResultCode: code, message: 'locked');
      expect(driver.isRetryableError(error(5)), isTrue); // SQLITE_BUSY
      expect(driver.isRetryableError(error(517)), isTrue); // BUSY_SNAPSHOT
      expect(driver.isRetryableError(error(6)), isTrue); // SQLITE_LOCKED
      expect(driver.isRetryableError(error(2067)), isFalse); // UNIQUE
      expect(driver.isRetryableError(StateError('x')), isFalse);
    });

    test('attempts: retries a busy transaction', () async {
      final db = sqliteInMemory();
      addTearDown(db.closeAll);
      var runs = 0;
      final result = await db.transaction(() async {
        if (++runs == 1) {
          throw SqliteException(
            extendedResultCode: 517,
            message: 'database is locked',
          );
        }
        return runs;
      }, attempts: 3);
      expect(result, 2);
    });

    test('the busy timeout comes from the busy_timeout option', () {
      SqliteDriver driver(Object? value) => SqliteDriver.fromConfig(
        'sqlite',
        ConnectionConfig(
          driver: 'sqlite',
          database: ':memory:',
          options: {'busy_timeout': value},
        ),
      );
      expect(driver(null).busyTimeout, const Duration(seconds: 5));
      expect(driver(250).busyTimeout, const Duration(milliseconds: 250));
      expect(driver('1500').busyTimeout, const Duration(milliseconds: 1500));
    });
  });

  test('a query waiting on a transaction it is not part of gives up '
      'after the busy timeout', () async {
    final driver = SqliteDriver(
      path: ':memory:',
      busyTimeout: const Duration(milliseconds: 100),
    );
    await driver.connect();
    addTearDown(driver.close);
    await driver.execute('CREATE TABLE items (name TEXT)');
    final started = Completer<void>();
    final outside = Completer<Object?>();
    // The transaction waits for a query that started outside it, as for a
    // shared cache fill another request began: that query can never run.
    final transaction = driver.transaction((tx) async {
      started.complete();
      await outside.future;
    });
    await started.future;
    // Outside the transaction's zone.
    final error = await driver
        .select('SELECT count(*) AS n FROM items')
        .then<Object?>((_) => null, onError: (Object e) => e);
    outside.complete(error);
    await transaction;
    expect(
      error,
      isA<SqliteException>().having((e) => e.resultCode, 'code', 5),
    );
    // Once it ended, outside queries run again.
    expect(await driver.select('SELECT count(*) AS n FROM items'), [
      {'n': 0},
    ]);
  });

  group('listeners can be removed', () {
    late DatabaseManager db;

    setUp(() => db = sqliteInMemory());
    tearDown(() => db.closeAll());

    test('query and transaction listeners', () async {
      final queries = <String>[];
      final transactions = <TransactionEvent>[];
      final stopQueries = db.listen((event) => queries.add(event.sql));
      final stopTransactions = db.listenTransactions(transactions.add);
      await db.transaction(() => db.select('SELECT 1'));
      expect(queries, ['SELECT 1']);
      expect(transactions, hasLength(2));
      stopQueries();
      stopTransactions();
      await db.transaction(() => db.select('SELECT 2'));
      expect(queries, ['SELECT 1']);
      expect(transactions, hasLength(2));
    });

    test('a listener removed while listeners run', () async {
      final calls = <String>[];
      late void Function() stopFirst;
      stopFirst = db.listen((_) {
        calls.add('first');
        stopFirst();
      });
      db.listen((_) => calls.add('second'));
      await db.select('SELECT 1');
      await db.select('SELECT 2');
      expect(calls, ['first', 'second', 'second']);
    });

    test('duration handlers keep firing after another is removed', () async {
      final fired = <String>[];
      final stopFirst = db.whenQueryingForLongerThan(
        Duration.zero,
        (_) => fired.add('first'),
      );
      stopFirst();
      db.whenQueryingForLongerThan(Duration.zero, (_) => fired.add('second'));
      await db.select('SELECT 1');
      await db.select('SELECT 2');
      // Once per scope: the isolate's, here.
      expect(fired, ['second']);
    });
  });

  test('closeAll closes every connection it can', () async {
    final closed = <String>[];
    final hang = Completer<void>();
    addTearDown(hang.complete);
    final db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'failing',
        connections: {
          'failing': ConnectionConfig(driver: 'failing', database: ':memory:'),
          'hanging': ConnectionConfig(driver: 'hanging', database: ':memory:'),
          'fine': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
      drivers: {
        'failing': (name, _) =>
            _ClosingDriver(name, () => throw StateError('close failed')),
        'hanging': (name, _) => _ClosingDriver(name, () => hang.future),
        'sqlite': (name, _) =>
            _ClosingDriver(name, () async => closed.add(name)),
      },
    );
    for (final name in ['failing', 'hanging', 'fine']) {
      await db.connection(name);
    }
    await expectLater(
      db.closeAll(timeout: const Duration(milliseconds: 50)),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'close failed'),
      ),
    );
    expect(closed, ['fine']);
    expect(db.hasOpenConnections, isFalse);
  });
}

/// An in-memory SQLite connection whose [close] runs [onClose].
final class _ClosingDriver implements DatabaseDriver {
  _ClosingDriver(this.name, this.onClose)
    : _inner = SqliteDriver(path: ':memory:', name: name);

  @override
  final String name;
  final Future<void> Function() onClose;
  final SqliteDriver _inner;

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  bool get isConnected => _inner.isConnected;

  @override
  Future<void> connect() => _inner.connect();

  @override
  Future<void> close() async {
    await _inner.close();
    await onClose();
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.select(sql, bindings);

  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.execute(sql, bindings);

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.insertGetId(sql, bindings);

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _inner.transaction(body);
}
