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
  });

  final String sql;
  final List<Object?> bindings;
  final Duration time;
  final String connectionName;

  @override
  String toString() =>
      'QueryExecuted($connectionName, ${time.inMicroseconds} µs: $sql)';
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
    final result = await run();
    final event = QueryExecuted(
      sql: sql,
      bindings: bindings,
      time: watch.elapsed,
      connectionName: connectionName,
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
