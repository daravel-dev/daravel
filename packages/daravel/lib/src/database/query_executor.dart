import 'dart:async';

/// SQL dialects known to the framework.
enum SqlDialect { sqlite, postgres, mysql }

/// Executes parameterized SQL. Bindings use `?` placeholders in Tier 0; the
/// dialect-aware grammar (ADR-005) takes over placeholder emission in S5.
abstract interface class QueryExecutor {
  SqlDialect get dialect;

  /// Runs a query and returns the rows as column → value maps.
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]);

  /// Runs a statement and returns the number of affected rows.
  Future<int> execute(String sql, [List<Object?> bindings = const <Object?>[]]);

  /// Runs an insert and returns the generated primary key.
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]);
}

/// A connection to a database server or file.
abstract interface class DatabaseDriver implements QueryExecutor {
  /// Connection name as configured (`sqlite`, `pgsql`, ...).
  String get name;

  bool get isConnected;

  Future<void> connect();

  Future<void> close();

  /// Runs [body] inside a transaction; rolls back when it throws.
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body);
}

/// A driver that delivers notifications between connections to the same
/// database (PostgreSQL's `LISTEN` / `NOTIFY`), so other processes and
/// machines can be woken instead of polling.
abstract interface class NotifyingDriver implements DatabaseDriver {
  /// Payloads notified on [channel], from a connection of its own (a pooled
  /// one would drop the subscription); closed when the listener cancels.
  Stream<String> listen(String channel);
}

/// A query that ran (Laravel's `QueryExecuted`), passed to
/// `DatabaseManager.listen` / `DB.listen` listeners: SQL with its bindings,
/// duration and connection. For debugging, slow-query logging, N+1
/// detection and inspection tools.
final class QueryExecuted {
  const QueryExecuted({
    required this.sql,
    required this.bindings,
    required this.time,
    required this.connectionName,
    this.poolWait = Duration.zero,
  });

  final String sql;
  final List<Object?> bindings;

  /// Time in the database, without [poolWait].
  final Duration time;
  final String connectionName;

  /// Time spent waiting for a free connection. Zero inside a transaction,
  /// which holds its connection, and on SQLite. A high value with a low
  /// [time] means the pool is too small, not that the database is slow.
  final Duration poolWait;

  @override
  String toString() =>
      'QueryExecuted($connectionName, ${time.inMicroseconds} µs: $sql)';
}

/// The life of a transaction, for `DB.listenTransactions`. [depth] is 1 for
/// `BEGIN` and above that for a savepoint, as `transactionLevel()`.
sealed class TransactionEvent {
  const TransactionEvent(this.connectionName, this.depth);

  final String connectionName;
  final int depth;
}

final class DbTransactionBeginning extends TransactionEvent {
  const DbTransactionBeginning(
    super.connectionName,
    super.depth, {
    this.poolWait = Duration.zero,
  });

  /// The wait for a connection; zero for a savepoint, which has one.
  final Duration poolWait;
}

final class DbTransactionCommitted extends TransactionEvent {
  const DbTransactionCommitted(super.connectionName, super.depth, this.elapsed);

  final Duration elapsed;
}

final class DbTransactionRolledBack extends TransactionEvent {
  const DbTransactionRolledBack(
    super.connectionName,
    super.depth,
    this.elapsed,
    this.error,
  );

  final Duration elapsed;
  final Object error;
}

/// Filled by a pooled driver with the time a query waited for a connection.
/// It sits in the zone of a query only while a listener wants the number.
final class PoolWaitProbe {
  static final Object _key = Object();

  /// The probe of the running query, if any.
  static PoolWaitProbe? get current => Zone.current[_key] as PoolWaitProbe?;

  Duration waited = Duration.zero;

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: this});
}

/// Wraps an executor to report every query to [listeners]. Only used while
/// listeners are registered, so queries cost nothing extra otherwise.
final class ListeningQueryExecutor implements QueryExecutor {
  ListeningQueryExecutor(this.inner, this.connectionName, this.listeners);

  final QueryExecutor inner;
  final String connectionName;
  final List<void Function(QueryExecuted event)> listeners;

  @override
  SqlDialect get dialect => inner.dialect;

  Future<T> _timed<T>(
    String sql,
    List<Object?> bindings,
    Future<T> Function() run,
  ) async {
    final watch = Stopwatch()..start();
    final probe = PoolWaitProbe();
    final result = await probe.run(run);
    final event = QueryExecuted(
      sql: sql,
      bindings: bindings,
      time: watch.elapsed - probe.waited,
      connectionName: connectionName,
      poolWait: probe.waited,
    );
    for (final listener in List.of(listeners)) {
      listener(event);
    }
    return result;
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _timed(sql, bindings, () => inner.select(sql, bindings));

  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _timed(sql, bindings, () => inner.execute(sql, bindings));

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _timed(sql, bindings, () => inner.insertGetId(sql, bindings));
}

/// A driver that recognises its own transient errors (deadlocks, lock
/// timeouts), so `DB.transaction(attempts: n)` retries them.
abstract interface class RetryableErrors {
  bool isRetryableError(Object error);
}

/// A driver that recognises a unique index or primary key refusing a row
/// among its errors (Laravel's `isUniqueConstraintError`), so it surfaces
/// as [UniqueConstraintViolationException].
abstract interface class QueryErrors {
  bool isUniqueConstraintError(Object error);
}

/// A query the database refused (Laravel's `QueryException`): the driver's
/// error ([previous]) with the connection and the SQL.
///
/// Unlike Laravel's, the message keeps the `?` placeholders and only the
/// first line of the driver's error (SQLite's next lines repeat the SQL with
/// its parameters): the values, which may be password hashes or personal
/// data, are in [bindings], away from logs and error trackers. The
/// database's own words may still name a conflicting value (MySQL's
/// `Duplicate entry '...'`, PostgreSQL's detail), as in Laravel.
class QueryException implements Exception {
  QueryException(this.connectionName, this.sql, this.bindings, this.previous);

  final String connectionName;
  final String sql;
  final List<Object?> bindings;

  /// The driver's own error (`SqliteException`, `ServerException`,
  /// `MySQLServerException`, ...).
  final Object previous;

  String get message =>
      '${'$previous'.split('\n').first.trim()} '
      '(Connection: $connectionName, SQL: $sql)';

  @override
  String toString() => '$runtimeType: $message';
}

/// A row a unique index or primary key refused (Laravel's
/// `UniqueConstraintViolationException`): two requests registering the
/// same email at once, say. As in Laravel it is a server error unless
/// caught; `createOrFirst` and `firstOrCreate` catch it for you.
final class UniqueConstraintViolationException extends QueryException {
  UniqueConstraintViolationException(
    super.connectionName,
    super.sql,
    super.bindings,
    super.previous,
  );
}

/// Wraps an executor so a failing query throws [QueryException], or
/// [UniqueConstraintViolationException] when [errors] recognises one, as
/// Laravel's `runQueryCallback` does.
final class QueryExceptionExecutor implements QueryExecutor {
  QueryExceptionExecutor(this.inner, this.connectionName, this.errors);

  final QueryExecutor inner;
  final String connectionName;
  final QueryErrors? errors;

  @override
  SqlDialect get dialect => inner.dialect;

  Future<T> _guarded<T>(
    String sql,
    List<Object?> bindings,
    Future<T> Function() run,
  ) async {
    try {
      return await run();
    } on QueryException {
      rethrow;
    } on Exception catch (error, stack) {
      Error.throwWithStackTrace(
        errors?.isUniqueConstraintError(error) ?? false
            ? UniqueConstraintViolationException(
                connectionName,
                sql,
                bindings,
                error,
              )
            : QueryException(connectionName, sql, bindings, error),
        stack,
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _guarded(sql, bindings, () => inner.select(sql, bindings));

  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _guarded(sql, bindings, () => inner.execute(sql, bindings));

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _guarded(sql, bindings, () => inner.insertGetId(sql, bindings));
}
