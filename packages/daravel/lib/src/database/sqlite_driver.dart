import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'database_config.dart';
import 'orm/casts.dart' show formatDateTime;
import 'query_executor.dart';

/// SQLite driver backed by `package:sqlite3` (synchronous FFI).
///
/// One connection per isolate; transactions are serialized with an async
/// lock because SQLite is single-writer. While a transaction is open, queries
/// from outside it (another request on the same isolate) wait until it
/// commits or rolls back, so they never join or get rolled back with it;
/// queries from inside it are recognised by a zone token. A query that
/// waits longer than [busyTimeout] for one transaction fails with
/// `SQLITE_BUSY`, as a second connection would. File databases are opened
/// in WAL mode with that busy timeout (BLUEPRINT_V2 §2.2.4), and
/// transactions begin with `BEGIN IMMEDIATE`, so one that reads and then
/// writes never finds that another isolate wrote in between.
final class SqliteDriver
    implements DatabaseDriver, QueryErrors, RetryableErrors {
  /// SQLITE_CONSTRAINT_UNIQUE (2067) and SQLITE_CONSTRAINT_PRIMARYKEY
  /// (1555), as Laravel matches "UNIQUE constraint failed".
  @override
  bool isUniqueConstraintError(Object error) =>
      error is SqliteException &&
      (error.extendedResultCode == 2067 || error.extendedResultCode == 1555);

  /// `SQLITE_BUSY` (5, including `SQLITE_BUSY_SNAPSHOT`, 517) and
  /// `SQLITE_LOCKED` (6): another connection held the lock past the busy
  /// timeout, so `DB.transaction(attempts: n)` runs the body again.
  @override
  bool isRetryableError(Object error) =>
      error is SqliteException &&
      (error.extendedResultCode & 0xff == 5 ||
          error.extendedResultCode & 0xff == 6);

  /// A SQLite connection on the file [path] (`:memory:` for an in-memory
  /// database), named [name].
  SqliteDriver({
    required this.path,
    this.name = 'sqlite',
    this.busyTimeout = const Duration(seconds: 5),
  });

  /// The driver for a configured connection (`DB_DATABASE` is the file), as
  /// a `DatabaseDriverFactory`:
  /// `withDatabaseDriver('sqlite', SqliteDriver.fromConfig)`. The option
  /// `busy_timeout` (milliseconds, as in Laravel) sets [busyTimeout].
  factory SqliteDriver.fromConfig(String name, ConnectionConfig connection) {
    final busy = switch (connection.options['busy_timeout']) {
      final int ms => ms,
      final String ms => int.tryParse(ms),
      _ => null,
    };
    return SqliteDriver(
      path: connection.database,
      name: name,
      busyTimeout: busy == null || busy < 0
          ? const Duration(seconds: 5)
          : Duration(milliseconds: busy),
    );
  }

  /// File path, `:memory:` or a `file:` URI.
  final String path;

  @override
  final String name;

  /// How long a statement waits for a lock: another connection's (SQLite's
  /// `busy_timeout`), or a transaction of this connection that the
  /// statement is not part of. 5 seconds by default.
  final Duration busyTimeout;

  Database? _db;
  Future<void> _transactionQueue = Future<void>.value();

  /// Zone key holding the token of the transaction a zone runs in.
  static final Object _zoneKey = Object();

  /// Token and completion of the open transaction, if any.
  Object? _activeToken;
  Completer<void>? _activeDone;

  /// Waits while a transaction that the current zone is not part of is
  /// open, at most [busyTimeout] for each: a query started outside a
  /// transaction and awaited inside it would otherwise wait for ever.
  Future<void> _waitTurn() async {
    while (true) {
      final done = _activeDone;
      if (done == null || identical(Zone.current[_zoneKey], _activeToken)) {
        return;
      }
      try {
        await done.future.timeout(busyTimeout);
      } on TimeoutException {
        throw SqliteException(
          extendedResultCode: 5, // SQLITE_BUSY
          message: 'database is locked',
          explanation:
              'waited $busyTimeout for a transaction on this connection that the '
              'query is not part of (a query started outside DB.transaction '
              'and awaited inside it never gets its turn)',
        );
      }
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
    final Database db;
    try {
      db = sqlite3.open(path);
    } on ArgumentError catch (error) {
      if (!'$error'.contains('dynamic library')) {
        rethrow;
      }
      // A bundle built with `dartisan build --no-sqlite` loads SQLite from
      // the operating system, which may not have it.
      throw StateError(
        'SQLite is not available: this build leaves the SQLite library out '
        '(dartisan build --no-sqlite) and the operating system has none. '
        'Install it (e.g. apt install libsqlite3-0) or build with SQLite '
        'bundled. Cause: $error',
      );
    }
    try {
      if (!isMemory) {
        // First, so that switching to WAL (and every later statement) waits
        // for another isolate or process opening the same file instead of
        // failing with SQLITE_BUSY.
        db.execute('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
        await _enableWal(db);
        db.execute('PRAGMA synchronous = NORMAL');
      }
      db.execute('PRAGMA foreign_keys = ON');
    } on Object {
      // A file that is not a database (SQLITE_NOTADB), one that stays busy:
      // the handle was open and never closed, keeping the file locked, and
      // each retry (the manager connects again on the next query) leaked
      // one more.
      db.close();
      rethrow;
    }
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
            // IMMEDIATE takes the write lock now (waiting up to the busy
            // timeout for another isolate's), not at the first write: a
            // deferred transaction that read and then wrote after another
            // connection committed failed at once with
            // SQLITE_BUSY_SNAPSHOT, and two that both read first could
            // never both upgrade.
            _database.execute('BEGIN IMMEDIATE');
            try {
              final result = await runZoned(
                () => body(this),
                zoneValues: <Object?, Object?>{_zoneKey: token},
              );
              _database.execute('COMMIT');
              return result;
            } catch (error, stack) {
              _rollbackQuietly();
              // The body's error, not the rollback's.
              Error.throwWithStackTrace(error, stack);
            }
          } finally {
            _activeToken = null;
            _activeDone = null;
            done.complete();
          }
        })
        .whenComplete(release.complete);
  }

  /// Rolls back what is still open. SQLite ends the transaction itself on
  /// some errors (`SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_NOMEM`), and a body
  /// may have ended it (a SQL dump's `COMMIT`), where a `ROLLBACK` would
  /// only throw "no transaction is active" over the error that matters.
  void _rollbackQuietly() {
    final db = _db;
    if (db == null || db.autocommit) {
      return;
    }
    try {
      db.execute('ROLLBACK');
    } on Object {
      // The original error is what the caller needs to see.
    }
  }

  static List<Object?> _normalize(List<Object?> bindings) => <Object?>[
    for (final value in bindings)
      switch (value) {
        bool() => value ? 1 : 0,
        // Laravel's Grammar::getDateFormat() (Y-m-d H:i:s), which models
        // write too: SQLite compares dates as text, so one format only.
        DateTime() => formatDateTime(value),
        Enum() => value.name,
        _ => value,
      },
  ];
}
