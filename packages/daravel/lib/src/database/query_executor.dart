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
