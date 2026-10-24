import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'query_executor.dart';

/// SQLite driver backed by `package:sqlite3` (synchronous FFI).
///
/// One connection per isolate; transactions are serialized with an async
/// lock because SQLite is single-writer. File databases are opened in WAL
/// mode with a busy timeout (BLUEPRINT_V2 §2.2.4).
final class SqliteDriver implements DatabaseDriver {
  SqliteDriver({required this.path, this.name = 'sqlite'});

  /// File path, `:memory:` or a `file:` URI.
  final String path;

  @override
  final String name;

  Database? _db;
  Future<void> _transactionQueue = Future<void>.value();

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  bool get isConnected => _db != null;

  @override
  Future<void> connect() async {
    if (_db != null) {
      return;
    }
    final isMemory = path == ':memory:' || path.startsWith('file:');
    if (!isMemory) {
      final parent = File(path).parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
    }
    final db = sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON');
    if (!isMemory) {
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA synchronous = NORMAL');
    }
    _db = db;
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
  }

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError(
        'SQLite connection [$name] is not open; call connect() first.',
      );
    }
    return db;
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    final result = _database.select(sql, _normalize(bindings));
    return <Map<String, Object?>>[
      for (final row in result) Map<String, Object?>.of(row),
    ];
  }

  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    _database.execute(sql, _normalize(bindings));
    final changes = _database.select('SELECT changes() AS n');
    return (changes.first['n'] as num).toInt();
  }

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    _database.execute(sql, _normalize(bindings));
    final rows = _database.select('SELECT last_insert_rowid() AS id');
    return rows.first['id'];
  }

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) {
    final previous = _transactionQueue;
    final release = Completer<void>();
    _transactionQueue = release.future;
    return previous
        .then((_) async {
          await execute('BEGIN');
          try {
            final result = await body(this);
            await execute('COMMIT');
            return result;
          } catch (_) {
            await execute('ROLLBACK');
            rethrow;
          }
        })
        .whenComplete(release.complete);
  }

  static List<Object?> _normalize(List<Object?> bindings) => <Object?>[
    for (final value in bindings)
      switch (value) {
        bool() => value ? 1 : 0,
        DateTime() => value.toUtc().toIso8601String(),
        Enum() => value.name,
        _ => value,
      },
  ];
}
