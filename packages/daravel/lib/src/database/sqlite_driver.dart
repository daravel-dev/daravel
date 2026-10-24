import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'query_executor.dart';

/// SQLite driver backed by `package:sqlite3` (synchronous FFI).
///
/// One connection per isolate; transactions are serialized with an async
/// lock because SQLite is single-writer. While a transaction is open, queries
/// from outside it (another request on the same isolate) wait until it
/// commits or rolls back, so they never join or get rolled back with it;
/// queries from inside it are recognised by a zone token. File databases are opened in WAL
/// mode with a busy timeout (BLUEPRINT_V2 §2.2.4).
final class SqliteDriver implements DatabaseDriver {
  SqliteDriver({required this.path, this.name = 'sqlite'});

  /// File path, `:memory:` or a `file:` URI.
  final String path;

  @override
  final String name;

  Database? _db;
  Future<void> _transactionQueue = Future<void>.value();

  /// Zone key holding the token of the transaction a zone runs in.
  static final Object _zoneKey = Object();

  /// Token and completion of the open transaction, if any.
  Object? _activeToken;
  Completer<void>? _activeDone;

  /// Waits while a transaction that the current zone is not part of is open.
  Future<void> _waitTurn() async {
    while (true) {
      final done = _activeDone;
      if (done == null || identical(Zone.current[_zoneKey], _activeToken)) {
        return;
      }
      await done.future;
    }
  }

  bool get _mustWait =>
      _activeDone != null && !identical(Zone.current[_zoneKey], _activeToken);

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
    if (!isMemory) {
      // First, so that switching to WAL (and every later statement) waits
      // for another isolate or process opening the same file instead of
      // failing with SQLITE_BUSY.
      db.execute('PRAGMA busy_timeout = 5000');
      await _enableWal(db);
      db.execute('PRAGMA synchronous = NORMAL');
    }
    db.execute('PRAGMA foreign_keys = ON');
    _db = db;
  }

  /// Switches the file to WAL. The mode is stored in the file, so only the
  /// first connection has to set it; when several isolates open a new file
  /// at once, the switch answers SQLITE_BUSY without consulting the busy
  /// timeout, so it is retried briefly.
  static Future<void> _enableWal(Database db) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var delay = const Duration(milliseconds: 5);
    while (true) {
      try {
        final mode = db.select('PRAGMA journal_mode').first.values.first;
        if ('$mode'.toLowerCase() == 'wal') {
          return;
        }
        db.execute('PRAGMA journal_mode = WAL');
        return;
      } on SqliteException catch (error) {
        final busy = error.extendedResultCode & 0xff == 5; // SQLITE_BUSY
        if (!busy || DateTime.now().isAfter(deadline)) {
          rethrow;
        }
      }
      await Future<void>.delayed(delay);
      if (delay < const Duration(milliseconds: 100)) {
        delay *= 2;
      }
    }
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
    if (_mustWait) {
      await _waitTurn();
    }
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
    if (_mustWait) {
      await _waitTurn();
    }
    final db = _database..execute(sql, _normalize(bindings));
    return db.updatedRows;
  }

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    if (_mustWait) {
      await _waitTurn();
    }
    final db = _database..execute(sql, _normalize(bindings));
    return db.lastInsertRowId;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) {
    final previous = _transactionQueue;
    final release = Completer<void>();
    _transactionQueue = release.future;
    return previous
        .then((_) async {
          // SQLite calls are synchronous, so nothing else runs between this
          // point and BEGIN: queries outside the transaction see the token
          // before the transaction has written anything.
          final token = Object();
          final done = Completer<void>();
          _activeToken = token;
          _activeDone = done;
          try {
            _database.execute('BEGIN');
            try {
              final result = await runZoned(
                () => body(this),
                zoneValues: <Object?, Object?>{_zoneKey: token},
              );
              _database.execute('COMMIT');
              return result;
            } catch (_) {
              _database.execute('ROLLBACK');
              rethrow;
            }
          } finally {
            _activeToken = null;
            _activeDone = null;
            done.complete();
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
