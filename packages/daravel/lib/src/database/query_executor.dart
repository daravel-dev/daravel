import 'dart:async';

/// SQL dialects known to the framework.
enum SqlDialect {
  /// SQLite, through `package:sqlite3`.
  sqlite,

  /// PostgreSQL, through `package:postgres`.
  postgres,

  /// MySQL (`daravel_mysql`).
  mysql,

  /// MariaDB (`daravel_mysql`); MySQL's grammar with MariaDB's vectors.
  mariadb;

  /// MySQL or MariaDB: the same grammar, but for what MariaDB adds.
  bool get isMySqlFamily => this == mysql || this == mariadb;
}

/// Executes parameterized SQL. Bindings use `?` placeholders in Tier 0; the
/// dialect-aware grammar (ADR-005) takes over placeholder emission in S5.
abstract interface class QueryExecutor {
  /// The SQL dialect of this connection.
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

  /// Whether the connection is open.
  bool get isConnected;

  /// Opens the connection; called before the first query.
  Future<void> connect();

  /// Closes the connection and its pool.
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

/// A driver whose server sessions can be ended from another connection
/// (PostgreSQL's `pg_terminate_backend`, MySQL's `KILL CONNECTION`).
///
/// Killing an isolate does not close its sockets while the process lives:
/// a connection it left inside a transaction stays open on the server,
/// still holding its locks. A supervisor that kills a worker isolate asks
/// the worker for its [sessionIds] beforehand (through
/// `DatabaseManager.openSessions`) and ends them afterwards with
/// [terminateSession] on a driver of its own, so the server rolls their
/// transactions back at once.
abstract interface class SessionTerminatingDriver implements DatabaseDriver {
  /// The server's ids of the sessions this driver's pool holds open
  /// (PostgreSQL backend pids, MySQL connection ids), as strings.
  List<String> sessionIds();

  /// Ends the server session [id] (from [sessionIds] of a driver on the same
  /// server), rolling back its transaction. `false` when the server knows
  /// no such session; throws when the user may not end it.
  Future<bool> terminateSession(String id);
}

/// A query that ran (Laravel's `QueryExecuted`), passed to
/// `DatabaseManager.listen` / `DB.listen` listeners: SQL with its bindings,
/// duration and connection. For debugging, slow-query logging, N+1
/// detection and inspection tools.
final class QueryExecuted {
  /// A query that ran, as `DB.listen` reports it.
  const QueryExecuted({
    required this.sql,
    required this.bindings,
    required this.time,
    required this.connectionName,
    this.poolWait = Duration.zero,
  });

  /// The SQL, with placeholders.
  final String sql;

  /// The bound values.
  final List<Object?> bindings;

  /// Time in the database, without [poolWait].
  final Duration time;

  /// The connection it ran on.
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
  /// An event of the transaction at [depth] (1 for the outer one) on
  /// [connectionName].
  const TransactionEvent(this.connectionName, this.depth);

  /// The connection of the transaction.
  final String connectionName;

  /// The nesting level: 1 for the outer transaction, more for savepoints.
  final int depth;
}

/// A transaction or savepoint is starting.
final class DbTransactionBeginning extends TransactionEvent {
  /// Reports a transaction beginning on [connectionName] at [depth].
  const DbTransactionBeginning(
    super.connectionName,
    super.depth, {
    this.poolWait = Duration.zero,
  });

  /// The wait for a connection; zero for a savepoint, which has one.
  final Duration poolWait;
}

/// A transaction or savepoint committed.
final class DbTransactionCommitted extends TransactionEvent {
  /// Reports a commit after [elapsed].
  const DbTransactionCommitted(super.connectionName, super.depth, this.elapsed);

  /// How long the transaction ran.
  final Duration elapsed;
}

/// A transaction or savepoint rolled back.
final class DbTransactionRolledBack extends TransactionEvent {
  /// Reports a rollback after [elapsed], caused by [error].
  const DbTransactionRolledBack(
    super.connectionName,
    super.depth,
    this.elapsed,
    this.error,
  );

  /// How long the transaction ran.
  final Duration elapsed;

  /// The error that rolled it back.
  final Object error;
}

/// Filled by a pooled driver with the time a query waited for a connection.
/// It sits in the zone of a query only while a listener wants the number.
final class PoolWaitProbe {
  static final Object _key = Object();

  /// The probe of the running query, if any.
  static PoolWaitProbe? get current => Zone.current[_key] as PoolWaitProbe?;

  /// The time the query waited for a pooled connection.
  Duration waited = Duration.zero;

  /// Runs [body] with this probe in its zone.
  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: this});
}

/// Wraps an executor to report every query to [listeners]. Only used while
/// listeners are registered, so queries cost nothing extra otherwise.
final class ListeningQueryExecutor
    implements QueryExecutor, UnpreparedExecutor {
  /// Reports the queries of [inner] on [connectionName] to [listeners].
  ListeningQueryExecutor(this.inner, this.connectionName, this.listeners);

  /// The wrapped executor.
  final QueryExecutor inner;

  /// The connection name reported.
  final String connectionName;

  /// The `DB.listen` callbacks.
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

  @override
  Future<void> unprepared(String sql) =>
      _timed(sql, const <Object?>[], () => UnpreparedExecutor.run(inner, sql));
}

/// A driver that recognises its own transient errors (deadlocks, lock
/// timeouts), so `DB.transaction(attempts: n)` retries them.
abstract interface class RetryableErrors {
  /// Whether [error] is transient (a deadlock or lock timeout) and the
  /// transaction may be retried.
  bool isRetryableError(Object error);
}

/// A driver that recognises a value its database refused to read as the
/// column's type (a data exception, SQLSTATE class 22), so route model
/// binding answers `404` for it instead of `500`. PostgreSQL's is built in.
abstract interface class DataExceptionErrors {
  /// Whether [error] is the database refusing a value as its column's type.
  bool isDataException(Object error);
}

/// An executor that runs SQL as it is, unprepared (`DB.unprepared`,
/// Laravel's `DB::unprepared`): several statements in one call, and
/// statements a server cannot prepare. `select`, `statement` and
/// `insertGetId` run one statement and refuse more on every built-in
/// driver. Nothing is bound here, so never build the SQL from input. Every
/// executor of the built-in drivers implements it; a driver of another
/// package may not.
abstract interface class UnpreparedExecutor {
  /// Runs [sql] unprepared; it may hold several statements.
  Future<void> unprepared(String sql);

  /// [executor]'s [unprepared], or an [UnsupportedError] for an executor
  /// that has none.
  static Future<void> run(QueryExecutor executor, String sql) =>
      switch (executor) {
        final UnpreparedExecutor unprepared => unprepared.unprepared(sql),
        _ => throw UnsupportedError(
          'This database driver (${executor.runtimeType}) cannot run '
          'unprepared SQL.',
        ),
      };
}

/// SQL text a driver refused for its shape before the database saw it
/// (SQLite's); the connection reports it as a `QueryException`.
sealed class SqlTextException implements Exception {
  const SqlTextException(this.message);

  /// What was refused.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// SQL holding several statements where `select`, `statement` or
/// `insertGetId` run one (SQLite's; MySQL and PostgreSQL refuse it with
/// their own syntax error). Run a script with `DB.unprepared`.
final class MultipleStatementsException extends SqlTextException {
  /// The SQL was refused for [message].
  const MultipleStatementsException(super.message);
}

/// SQL holding no statement (empty, blanks, a comment, `;`) given
/// bindings, or to `select` (SQLite's). Without bindings, `statement` and
/// `insertGetId` treat it as nothing to do.
final class NoStatementException extends SqlTextException {
  /// The SQL was refused for [message].
  const NoStatementException(super.message);
}

/// SQL holding a NUL character (code unit 0), refused before it reaches
/// SQLite: `package:sqlite3` looped for ever on it in `select`, and
/// `sqlite3_exec` silently stopped at it.
final class NulInSqlException extends SqlTextException {
  /// The SQL was refused for [message].
  const NulInSqlException(super.message);
}

/// A driver that recognises a unique index or primary key refusing a row
/// among its errors (Laravel's `isUniqueConstraintError`), so it surfaces
/// as [UniqueConstraintViolationException].
abstract interface class QueryErrors {
  /// Whether [error] is a unique index or primary key refusing a row.
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
  /// The error [previous] of [sql] with [bindings] on [connectionName].
  QueryException(this.connectionName, this.sql, this.bindings, this.previous);

  /// The connection the query ran on.
  final String connectionName;

  /// The SQL, with placeholders.
  final String sql;

  /// The bound values; kept out of [message].
  final List<Object?> bindings;

  /// The driver's own error (`SqliteException`, `ServerException`,
  /// `MySQLServerException`, ...).
  final Object previous;

  /// The driver's first line of error, with the connection and the SQL.
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
  /// A refused row; see [QueryException].
  UniqueConstraintViolationException(
    super.connectionName,
    super.sql,
    super.bindings,
    super.previous,
  );
}

/// No connection of the pool became free within the connect timeout
/// (`DB_CONNECT_TIMEOUT`): every connection is held by a query or a
/// transaction. Distinct from a slow query; raise `DB_POOL_SIZE` or keep
/// transactions short (`DB.transaction(timeout:)`). [sql] is empty when
/// the connection was wanted for a transaction.
final class PoolExhaustedException extends QueryException {
  /// The pool of [connectionName] had no free connection for [waited].
  PoolExhaustedException(
    String connectionName,
    this.waited, {
    String sql = '',
    List<Object?> bindings = const <Object?>[],
  }) : super(
         connectionName,
         sql,
         bindings,
         TimeoutException(
           'No connection of the pool became free within $waited',
           waited,
         ),
       );

  /// How long the caller waited for a connection.
  final Duration waited;
}

/// Wraps an executor so a failing query throws [QueryException], or
/// [UniqueConstraintViolationException] when [errors] recognises one, as
/// Laravel's `runQueryCallback` does.
final class QueryExceptionExecutor
    implements QueryExecutor, UnpreparedExecutor {
  /// Wraps [inner], recognising unique violations through [errors].
  QueryExceptionExecutor(this.inner, this.connectionName, this.errors);

  /// The wrapped executor.
  final QueryExecutor inner;

  /// The connection name reported in errors.
  final String connectionName;

  /// The driver's error classifier, when it has one.
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
    } on TransactionTimeoutException {
      // Not the query's failure: the transaction it was part of timed out.
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

  @override
  Future<void> unprepared(String sql) => _guarded(
    sql,
    const <Object?>[],
    () => UnpreparedExecutor.run(inner, sql),
  );
}

/// A transaction (or savepoint) still running when its `timeout` passed
/// ([DatabaseManager.transaction]): it was rolled back, and later queries
/// of its body throw this too.
final class TransactionTimeoutException extends TimeoutException {
  /// A transaction given up after [timeout].
  TransactionTimeoutException(Duration timeout)
    : super(
        'The database transaction did not finish within $timeout; it was '
        'rolled back.',
        timeout,
      );
}
