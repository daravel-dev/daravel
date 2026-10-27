import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// SQLite with one error of our own declared retryable, as PostgreSQL's
/// deadlocks and serialization failures are.
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

/// `DB.transaction(attempts: n)` retries the body on a deadlock. An
/// after-commit callback that fails with one must not: the body committed,
/// and running it again would commit its writes twice.
void main() {
  late Directory dir;
  late DatabaseManager db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('after_commit_retry_');
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

  test('a retryable error in the body retries it', () async {
    var runs = 0;
    await db.transaction(attempts: 3, () async {
      runs++;
      await db.statement("INSERT INTO items VALUES ('row')");
      if (runs < 3) {
        throw StateError('deadlock');
      }
    });
    expect(runs, 3);
    final rows = await db.select('SELECT COUNT(*) AS n FROM items');
    expect(rows.first['n'], 1, reason: 'the failed attempts rolled back');
  });

  test('a retryable error in a callback never re-runs the body', () async {
    var runs = 0;
    await expectLater(
      db.transaction(attempts: 3, () async {
        runs++;
        await db.statement("INSERT INTO items VALUES ('row')");
        await db.afterCommit(() => throw StateError('deadlock'));
      }),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'deadlock'),
      ),
    );
    expect(runs, 1, reason: 'it committed; a retry would commit again');
    final rows = await db.select('SELECT COUNT(*) AS n FROM items');
    expect(rows.first['n'], 1);
  });
}
