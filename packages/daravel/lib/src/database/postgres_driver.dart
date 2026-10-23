import 'dart:async';

import 'package:postgres/postgres.dart' as pg;

import 'query_executor.dart';

/// SSL modes exposed without leaking the `postgres` package type.
enum PostgresSslMode { disable, require, verifyFull }

/// PostgreSQL driver backed by `package:postgres` (pure Dart, pooled).
///
/// SQL handed to this driver must already use `$n` placeholders (the query
/// grammar emits them; raw SQL is expanded by `SqlBindings`). Transactions
/// run on a dedicated pooled connection; the executor passed to the callback
/// is the only object that may issue queries inside the transaction.
final class PostgresDriver implements DatabaseDriver {
  PostgresDriver({
    required this.host,
    required this.database,
    this.port = 5432,
    this.username,
    this.password,
    this.name = 'pgsql',
    this.maxConnections = 10,
    this.sslMode = PostgresSslMode.disable,
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout = const Duration(seconds: 30),
    this.applicationName = 'daravel',
  });

  final String host;
  final int port;
  final String database;
  final String? username;
  final String? password;
  final int maxConnections;
  final PostgresSslMode sslMode;
  final Duration connectTimeout;
  final Duration queryTimeout;
  final String applicationName;

  @override
  final String name;

  pg.Pool<Object?>? _pool;

  @override
  SqlDialect get dialect => SqlDialect.postgres;

  @override
  bool get isConnected => _pool != null;

  /// SQLSTATE codes that make a transaction worth retrying.
  static const Set<String> retryableCodes = {'40P01', '40001'};

  /// Whether [error] is a deadlock / serialization failure.
  static bool isRetryable(Object error) =>
      error is pg.ServerException && retryableCodes.contains(error.code);

  @override
  Future<void> connect() async {
    if (_pool != null) {
      return;
    }
    final pool = pg.Pool<Object?>.withEndpoints(
      [
        pg.Endpoint(
          host: host,
          port: port,
          database: database,
          username: username,
          password: password,
        ),
      ],
      settings: pg.PoolSettings(
        maxConnectionCount: maxConnections,
        sslMode: switch (sslMode) {
          PostgresSslMode.disable => pg.SslMode.disable,
          PostgresSslMode.require => pg.SslMode.require,
          PostgresSslMode.verifyFull => pg.SslMode.verifyFull,
        },
        connectTimeout: connectTimeout,
        queryTimeout: queryTimeout,
        applicationName: applicationName,
      ),
    );
    // Fail fast on bad credentials/hosts instead of at the first query.
    await pool.execute(pg.Sql('SELECT 1'));
    _pool = pool;
  }

  @override
  Future<void> close() async {
    final pool = _pool;
    _pool = null;
    await pool?.close();
  }

  pg.Pool<Object?> get _session {
    final pool = _pool;
    if (pool == null) {
      throw StateError(
        'PostgreSQL connection [$name] is not open; call connect() first.',
      );
    }
    return pool;
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _PgExecutor(_session).select(sql, bindings);

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) =>
      _PgExecutor(_session).execute(sql, bindings);

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _PgExecutor(_session).insertGetId(sql, bindings);

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _session.runTx<T>((session) => body(_PgExecutor(session)));
}

final class _PgExecutor implements QueryExecutor {
  _PgExecutor(this._session);

  final pg.Session _session;

  @override
  SqlDialect get dialect => SqlDialect.postgres;

  static List<Object?> _normalize(List<Object?> bindings) => [
    for (final value in bindings)
      switch (value) {
        DateTime() => value.toUtc(),
        Enum() => value.name,
        _ => value,
      },
  ];

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) async {
    final result = await _session.execute(
      pg.Sql(sql),
      parameters: _normalize(bindings),
    );
    return [for (final row in result) row.toColumnMap()];
  }

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) async {
    final result = await _session.execute(
      pg.Sql(sql),
      parameters: _normalize(bindings),
    );
    return result.affectedRows;
  }

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) async {
    final result = await _session.execute(
      pg.Sql(sql),
      parameters: _normalize(bindings),
    );
    if (result.isEmpty || result.first.isEmpty) {
      return null;
    }
    return result.first.first;
  }
}
