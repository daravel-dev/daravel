import '../foundation/container.dart';
import 'database_manager.dart';
import 'query_executor.dart';

/// Keys for tables that have no sequence, where Laravel code writes
/// `MAX(id) + 1`. Two requests doing that at once read the same maximum.
///
/// ```dart
/// final id = await LegacyKey.insert('kandidat', {'nama': nama});
/// ```
///
/// Each read waits for the writer before it until that writer commits: an
/// advisory lock on PostgreSQL, a row lock on MySQL and MariaDB, the write lock
/// on SQLite. `MAX(id) ... FOR UPDATE` is not valid SQL, and MySQL's
/// `GET_LOCK` cannot outlast a transaction on a pooled connection.
///
/// That only binds code that uses this class. Laravel writing to the same table
/// takes no lock, so [insert] tries again when the key is taken. On PostgreSQL
/// this needs the default `READ COMMITTED`: a snapshot from an older statement
/// cannot see the writer it waited for.
abstract final class LegacyKey {
  static const int _attempts = 5;

  /// The next key of [table]. The key is held only until the transaction ends,
  /// so this must run inside one, with the insert: outside, it would be free
  /// for anyone again before the caller used it.
  static Future<int> next(
    String table, {
    String column = 'id',
    String? connection,
  }) async {
    final db = _manager;
    if (!db.inTransactionOn(connection)) {
      throw StateError(
        'LegacyKey.next needs a transaction, or use LegacyKey.insert.',
      );
    }
    return _reserve(db, table, column, connection);
  }

  /// Inserts [values] under the next key of [table] and returns the key.
  static Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String column = 'id',
    String? connection,
  }) async {
    final db = _manager;
    for (var attempt = 1; ; attempt++) {
      try {
        return await db.transaction(
          () async {
            final key = await _reserve(db, table, column, connection);
            await db.table(table, connection: connection).insert({
              ...values,
              column: key,
            });
            return key;
          },
          connection: connection,
          // On MySQL writers deadlock on the gap above the last row. Each
          // deadlock lets one through, so this bounds the writers at once.
          attempts: 12,
        );
      } on UniqueConstraintViolationException {
        if (attempt >= _attempts) {
          rethrow;
        }
      }
    }
  }

  static DatabaseManager get _manager =>
      Container.current.make<DatabaseManager>();

  static Future<int> _reserve(
    DatabaseManager db,
    String table,
    String column,
    String? connection,
  ) async {
    final query = db.table(table, connection: connection);
    final dialect = db.dialectOf(connection);
    if (dialect.isMySqlFamily) {
      final row = await query
          .select([column])
          .orderBy(column, 'desc')
          .limit(1)
          .lockForUpdate()
          .first();
      return _integer(row?[column]) + 1;
    }
    if (dialect == .postgres) {
      // A hash collision only makes two tables wait for each other.
      await db.select('SELECT pg_advisory_xact_lock(hashtext(?))', [
        'legacy_key:$table.$column',
      ], connection);
    }
    return _integer(await query.max(column)) + 1;
  }

  static int _integer(Object? value) => switch (value) {
    null => 0,
    final num number => number.toInt(),
    final BigInt big => big.toInt(),
    _ => int.parse('$value'),
  };
}
