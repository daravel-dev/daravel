import 'package:sqlite3/sqlite3.dart';

/// `SQLITE_BUSY` or `SQLITE_LOCKED`: another connection kept the lock past
/// `busy_timeout`. With WAL, an application writer can do that while the
/// replicator waits, so a sync tries again later instead of failing.
bool isSqliteBusy(SqliteException error) =>
    error.resultCode == 5 || error.resultCode == 6;

/// Starts a write transaction on [db], or returns `false` when another
/// connection holds the write lock past `busy_timeout`.
bool tryBeginImmediate(Database db) {
  try {
    db.execute('BEGIN IMMEDIATE');
    return true;
  } on SqliteException catch (error) {
    if (!isSqliteBusy(error)) {
      rethrow;
    }
    return false;
  }
}
