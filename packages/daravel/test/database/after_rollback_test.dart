import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// SQLite whose `StateError('deadlock')` counts as retryable, so
/// `transaction(attempts:)` retries.
final class _RetryingSqlite implements DatabaseDriver, RetryableErrors {
  _RetryingSqlite(this._inner);

  final SqliteDriver _inner;

  @override
  bool isRetryableError(Object error) =>
      error is StateError && error.message == 'deadlock';

  @override
  SqlDialect get dialect => _inner.dialect;
  @override
  String get name => _inner.name;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  Future<void> connect() => _inner.connect();
  @override
  Future<void> close() => _inner.close();
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

/// `afterRollback` (G1.5): callbacks of the level that rolls back run, a
/// released savepoint passes its own to the level around it, a retry runs
/// them before the body runs again, and a failing one never hides the
/// error that caused the rollback. After-commit callbacks all run even
/// when one throws.
void main() {
  late Directory dir;
  late DatabaseManager db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('after_rollback_');
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'main',
        connections: {
          'main': ConnectionConfig(
            driver: 'retrying',
            database: p.join(dir.path, 'main.sqlite'),
          ),
        },
      ),
      drivers: {
        'retrying': (name, connection) =>
            _RetryingSqlite(SqliteDriver.fromConfig(name, connection)),
      },
    );
    await (await db.executor()).execute('CREATE TABLE items (name TEXT)');
  });

  tearDown(() async {
    await db.closeAll();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  test('a rollback runs the callbacks; a commit drops them', () async {
    final ran = <String>[];
    await expectLater(
      db.transaction(() async {
        db.afterRollback(() => ran.add('rolled back'));
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(ran, ['rolled back']);
    await db.transaction(() async {
      db.afterRollback(() => ran.add('never'));
    });
    expect(ran, ['rolled back']);
  });

  test('outside a transaction it does nothing', () async {
    var ran = false;
    db.afterRollback(() => ran = true);
    await db.statement("INSERT INTO items VALUES ('a')");
    expect(ran, isFalse);
  });

  test('a savepoint rolled back runs only its own; the outer level that '
      'commits keeps nothing', () async {
    final ran = <String>[];
    await db.transaction(() async {
      db.afterRollback(() => ran.add('outer'));
      await expectLater(
        db.transaction(() async {
          db.afterRollback(() => ran.add('inner'));
          throw StateError('inner fails');
        }),
        throwsStateError,
      );
    });
    expect(ran, ['inner']);
  });

  test('a savepoint released, then its parent rolled back: its callbacks '
      'still run (Laravel drops them; Daravel keeps them on purpose)', () async {
    final ran = <String>[];
    await expectLater(
      db.transaction(() async {
        await db.transaction(() async {
          db.afterRollback(() => ran.add('released savepoint'));
        });
        db.afterRollback(() => ran.add('outer'));
        throw StateError('outer fails');
      }),
      throwsStateError,
    );
    expect(ran, unorderedEquals(['released savepoint', 'outer']));
  });

  test('a retried transaction runs them before the body runs again', () async {
    final events = <String>[];
    var attempt = 0;
    await db.transaction(() async {
      attempt++;
      events.add('body $attempt');
      db.afterRollback(() => events.add('undo $attempt'));
      if (attempt == 1) {
        throw StateError('deadlock');
      }
    }, attempts: 3);
    expect(events, ['body 1', 'undo 1', 'body 2']);
  });

  test('a failing rollback callback is logged; the others run and the '
      'caller gets the error that caused the rollback', () async {
    final ran = <String>[];
    await expectLater(
      db.transaction(() async {
        db
          ..afterRollback(() => throw StateError('undo fails'))
          ..afterRollback(() => ran.add('second'));
        throw ArgumentError('the cause');
      }),
      throwsArgumentError,
    );
    expect(ran, ['second']);
  });

  test('after-commit callbacks all run when one throws; the caller gets the '
      'first error', () async {
    final ran = <String>[];
    await expectLater(
      db.transaction(() async {
        await db.afterCommit(() => throw StateError('first push fails'));
        await db.afterCommit(() => ran.add('second push'));
        await db.afterCommit(() => throw StateError('third push fails'));
      }),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'first push fails'),
      ),
    );
    expect(ran, ['second push']);
  });

  test('inside a test baseline, an application transaction that commits '
      'drops its rollback callbacks with it', () async {
    final ran = <String>[];
    await db.rollbackAfter(() async {
      await db.transaction(() async {
        db.afterRollback(() => ran.add('app transaction'));
      });
    });
    expect(ran, isEmpty);
  });
}
