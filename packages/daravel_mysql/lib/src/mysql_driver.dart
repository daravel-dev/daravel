import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart' as my;

/// MySQL and MariaDB driver (ADR-019), on the pure Dart `mysql_dart` client.
///
/// Register it in `bootstrap/app.dart`:
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
///     .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
/// ```
///
/// Queries with bindings run as server-side prepared statements (cached per
/// connection), so values never reach the SQL text. Values are read as
/// Laravel reads them: dates and times as `Y-m-d H:i:s` strings, which the
/// ORM parses as UTC. The session time zone is left to the server unless
/// `DB_TIMEZONE` is set, as in Laravel, so `TIMESTAMP` columns read the same
/// from both applications.
final class MySqlDriver
    implements DatabaseDriver, RetryableErrors, QueryErrors {
  MySqlDriver({
    required this.host,
    required this.database,
    this.port = 3306,
    this.username,
    this.password,
    this.name = 'mysql',
    this.maxConnections = 10,
    this.secure = false,
    this.collation = 'utf8mb4_unicode_ci',
    this.timeZone,
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout = const Duration(seconds: 30),
  });

  /// Builds the driver from a connection of `config/database` (`DB_*`).
  ///
  /// `DB_SSLMODE` other than `disable` turns TLS on; without TLS the client
  /// may fetch the server's RSA key, which MySQL 8's default
  /// `caching_sha2_password` needs on a first login.
  factory MySqlDriver.fromConfig(String name, ConnectionConfig connection) {
    final sslMode = '${connection.options['sslmode'] ?? 'disable'}';
    return MySqlDriver(
      name: name,
      host: connection.host ?? '127.0.0.1',
      port: connection.port ?? 3306,
      database: connection.database,
      username: connection.username,
      password: connection.password,
      maxConnections: (connection.options['pool'] as int?) ?? 10,
      secure: sslMode != 'disable',
      collation:
          (connection.options['collation'] as String?) ?? 'utf8mb4_unicode_ci',
      timeZone: connection.options['timezone'] as String?,
      connectTimeout:
          PostgresDriver.timeoutOption(
            connection.options['connect_timeout'],
            const Duration(seconds: 10),
          ) ??
          PostgresDriver.noTimeout,
      queryTimeout: PostgresDriver.timeoutOption(
        connection.options['query_timeout'],
        const Duration(seconds: 30),
      ),
    );
  }

  final String host;
  final int port;
  final String database;
  final String? username;
  final String? password;
  final int maxConnections;
  final bool secure;
  final String collation;
  final String? timeZone;
  final Duration connectTimeout;

  /// How long a statement may run (`DB_QUERY_TIMEOUT`, 30 s like
  /// PostgreSQL; `null` for none). Without it a statement stuck on a lock
  /// wait, a stalled replica or a half-open connection held its pooled
  /// connection for ever, and once `maxConnections` were stuck every
  /// request on the isolate queued behind them. On expiry `mysql_dart`
  /// issues `KILL QUERY` through a side connection.
  final Duration? queryTimeout;

  @override
  final String name;

  my.MySQLConnectionPool? _pool;

  @override
  SqlDialect get dialect => SqlDialect.mysql;

  @override
  bool get isConnected => _pool != null;

  /// MySQL errors worth retrying a whole transaction for: deadlock (1213)
  /// and lock wait timeout (1205).
  @override
  bool isRetryableError(Object error) =>
      error is MySQLServerException &&
      (error.errorCode == 1213 || error.errorCode == 1205);

  /// `ER_DUP_ENTRY` (1062), as Laravel matches "Integrity constraint
  /// violation: 1062".
  @override
  bool isUniqueConstraintError(Object error) =>
      error is MySQLServerException && error.errorCode == 1062;

  @override
  Future<void> connect() async {
    if (_pool != null) {
      return;
    }
    final pool = my.MySQLConnectionPool(
      host: host,
      port: port,
      userName: username ?? 'root',
      password: password ?? '',
      maxConnections: maxConnections,
      databaseName: database,
      secure: secure,
      collation: collation,
      timeoutMs: connectTimeout.inMilliseconds,
      allowPublicKeyRetrieval: !secure,
      timeZone: timeZone,
    );
    try {
      // Fail fast on bad credentials or hosts instead of at the first query.
      // Bounded: mysql_dart opens its socket without a timeout, so a host
      // that accepts the TCP connection and never answers the handshake
      // would hold connect() for ever.
      await pool.execute('SELECT 1').timeout(connectTimeout + probeGrace);
    } catch (_) {
      await pool.close();
      rethrow;
    }
    _pool = pool;
  }

  /// Added to [connectTimeout] for the `SELECT 1` probe of [connect].
  static const Duration probeGrace = Duration(seconds: 5);

  /// Statements running on the pool right now ([close] waits for them).
  int get inFlight => _inFlight;
  int _inFlight = 0;

  /// How long [close] waits for in-flight statements before closing the
  /// pool under them: `mysql_dart`'s pool close never completes the
  /// callers still queued for a connection, so draining first keeps a
  /// graceful shutdown from hanging on them.
  Duration get drainTimeout => queryTimeout ?? const Duration(seconds: 30);

  @override
  Future<void> close() async {
    final pool = _pool;
    _pool = null;
    if (pool == null) {
      return;
    }
    final deadline = DateTime.now().add(drainTimeout);
    while (_inFlight > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await pool.close();
  }

  my.MySQLConnectionPool get _session {
    final pool = _pool;
    if (pool == null) {
      throw StateError(
        'MySQL connection [$name] is not open; call connect() first.',
      );
    }
    return pool;
  }

  Future<T> _withConnection<T>(
    Future<T> Function(my.MySQLConnection connection) body,
  ) async {
    final pool = _session;
    _inFlight++;
    try {
      return await pool.withConnection<T>(body);
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _withConnection(
    (c) => _MySqlExecutor(c, queryTimeout).select(sql, bindings),
  );

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) =>
      _withConnection(
        (c) => _MySqlExecutor(c, queryTimeout).execute(sql, bindings),
      );

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _withConnection(
    (c) => _MySqlExecutor(c, queryTimeout).insertGetId(sql, bindings),
  );

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _withConnection(
        (connection) => connection.transactional<T>(
          (tx) => body(_MySqlExecutor(tx, queryTimeout)),
        ),
      );
}

/// Runs statements on one connection (a pooled one, or a transaction's).
final class _MySqlExecutor implements QueryExecutor {
  _MySqlExecutor(this._connection, this._queryTimeout);

  final my.MySQLConnection _connection;
  final Duration? _queryTimeout;

  @override
  SqlDialect get dialect => SqlDialect.mysql;

  /// Prepared-statement parameters in the form MySQL stores what Laravel
  /// writes.
  static List<Object?>? _normalize(List<Object?> bindings) => bindings.isEmpty
      ? null
      : [
          for (final value in bindings)
            switch (value) {
              bool() => value ? 1 : 0,
              DateTime() => formatDateTime(value),
              Enum() => value.name,
              Map<Object?, Object?>() ||
              List<Object?>() => value is Uint8List ? value : jsonEncode(value),
              _ => value,
            },
        ];

  Future<my.IResultSet> _run(String sql, List<Object?> bindings) =>
      _connection.execute(sql, _normalize(bindings), false, _queryTimeout);

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) async {
    final result = await _run(sql, bindings);
    // DATE (0x0a) and NEWDATE (0x0e): the binary protocol decoder adds a
    // midnight time that Laravel never sees.
    final dates = {
      for (final column in result.cols)
        if (column.type.intVal == 0x0a || column.type.intVal == 0x0e)
          column.name,
    };
    return [for (final row in result.rows) _row(row, dates)];
  }

  /// A row as Laravel reads it: numbers as numbers, TINYINT(1) as 0/1 (not
  /// bool), and dates and times as the server's `Y-m-d H:i:s` text rather
  /// than a local-time `DateTime` (the ORM parses them as UTC).
  static Map<String, Object?> _row(my.ResultSetRow row, Set<String> dates) {
    final raw = row.assoc();
    return {
      for (final MapEntry(:key, :value) in row.typedAssoc().entries)
        key: switch (value) {
          bool() => value ? 1 : 0,
          DateTime() => _text(raw[key], date: dates.contains(key)),
          _ => value,
        },
    };
  }

  static Object? _text(Object? raw, {required bool date}) =>
      date && raw is String && raw.length > 10 ? raw.substring(0, 10) : raw;

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) async =>
      (await _run(sql, bindings)).affectedRows.toInt();

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) async {
    final id = (await _run(sql, bindings)).lastInsertID;
    return id == BigInt.zero ? null : id.toInt();
  }
}
