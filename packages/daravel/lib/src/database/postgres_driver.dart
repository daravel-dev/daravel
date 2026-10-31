import 'dart:async';

import 'package:postgres/postgres.dart' as pg;

import 'database_config.dart';
import 'query_executor.dart';

/// SSL modes exposed without leaking the `postgres` package type.
enum PostgresSslMode { disable, require, verifyFull }

/// PostgreSQL driver backed by `package:postgres` (pure Dart, pooled).
///
/// SQL handed to this driver must already use `$n` placeholders (the query
/// grammar emits them; raw SQL is expanded by `SqlBindings`). Transactions
/// run on a dedicated pooled connection; the executor passed to the callback
/// is the only object that may issue queries inside the transaction.
final class PostgresDriver implements NotifyingDriver, QueryErrors {
  /// SQLSTATE 23505 (`unique_violation`), as Laravel checks it.
  @override
  bool isUniqueConstraintError(Object error) =>
      error is pg.ServerException && error.code == '23505';

  PostgresDriver({
    required this.host,
    required this.database,
    this.port = 5432,
    this.username,
    this.password,
    this.name = 'pgsql',
    this.maxConnections = 10,
    this.sslMode = .disable,
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout = const Duration(seconds: 30),
    this.applicationName = 'daravel',
    this.searchPath = const <String>[],
  });

  /// The driver for a configured connection (`DB_HOST`, `DB_PORT`,
  /// `DB_POOL_SIZE`, `DB_SSLMODE`, ...), as a `DatabaseDriverFactory`:
  /// `withDatabaseDriver('pgsql', PostgresDriver.fromConfig)`.
  factory PostgresDriver.fromConfig(String name, ConnectionConfig connection) =>
      PostgresDriver(
        name: name,
        host: connection.host ?? '127.0.0.1',
        port: connection.port ?? 5432,
        database: connection.database,
        username: connection.username,
        password: connection.password,
        maxConnections: (connection.options['pool'] as int?) ?? 10,
        sslMode: switch (connection.options['sslmode']) {
          'require' => PostgresSslMode.require,
          'verify-full' || 'verifyFull' => PostgresSslMode.verifyFull,
          _ => PostgresSslMode.disable,
        },
        connectTimeout:
            timeoutOption(
              connection.options['connect_timeout'],
              const Duration(seconds: 10),
            ) ??
            noTimeout,
        queryTimeout:
            timeoutOption(
              connection.options['query_timeout'],
              const Duration(seconds: 30),
            ) ??
            noTimeout,
        searchPath: parseSearchPath(connection.options['search_path']),
      );

  /// `DB_SEARCH_PATH` (`billing, hr, public`), as Laravel's
  /// `ParsesSearchPath`: names separated by commas or spaces, quotes dropped.
  static List<String> parseSearchPath(Object? value) => value is String
      ? [for (final m in RegExp(r'''[^\s,"']+''').allMatches(value)) m[0]!]
      : const <String>[];

  /// `set search_path to ...` as `PostgresConnector` quotes it.
  static String searchPathStatement(List<String> schemas) =>
      'set search_path to "${schemas.join('", "')}"';

  /// What `DB_QUERY_TIMEOUT=0` means for a driver whose timeout cannot be
  /// absent: longer than any deployment.
  static const Duration noTimeout = Duration(days: 365);

  /// A timeout option in seconds (`DB_QUERY_TIMEOUT`, `DB_CONNECT_TIMEOUT`):
  /// unset means [fallback], `0` means none (`null`).
  static Duration? timeoutOption(Object? value, Duration fallback) {
    final seconds = switch (value) {
      final int n => n,
      final String s => int.tryParse(s),
      _ => null,
    };
    if (seconds == null) {
      return fallback;
    }
    return seconds <= 0 ? null : Duration(seconds: seconds);
  }

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

  /// Set on every connection of the pool; the server's default when empty.
  final List<String> searchPath;

  @override
  final String name;

  pg.Pool<Object?>? _pool;

  /// The socket file when [host] is a path (`/cloudsql/project:region:db`),
  /// as libpq and Laravel read it: a directory gets `.s.PGSQL.<port>`
  /// appended. `null` for TCP hosts.
  String? get unixSocketPath {
    if (!host.startsWith('/')) {
      return null;
    }
    final file = '.s.PGSQL.$port';
    if (host.endsWith('/$file')) {
      return host;
    }
    return host.endsWith('/') ? '$host$file' : '$host/$file';
  }

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
      [_endpoint],
      settings: pg.PoolSettings(
        maxConnectionCount: maxConnections,
        sslMode: switch (sslMode) {
          .disable => pg.SslMode.disable,
          .require => pg.SslMode.require,
          .verifyFull => pg.SslMode.verifyFull,
        },
        connectTimeout: connectTimeout,
        queryTimeout: queryTimeout,
        applicationName: applicationName,
        onOpen: searchPath.isEmpty
            ? null
            : (connection) async {
                await connection.execute(searchPathStatement(searchPath));
              },
      ),
    );
    // Fail fast on bad credentials/hosts instead of at the first query.
    try {
      await pool.execute(pg.Sql('SELECT 1'));
    } catch (_) {
      // A probe that fails after the connection opened (a query timeout on
      // an overloaded server) would leave a live backend in a pool nothing
      // references, and the manager connects again on the next query.
      await pool.close(force: true);
      rethrow;
    }
    _pool = pool;
  }

  @override
  Future<void> close() async {
    final pool = _pool;
    _pool = null;
    await pool?.close();
  }

  pg.Endpoint get _endpoint => pg.Endpoint(
    host: unixSocketPath ?? host,
    isUnixSocket: unixSocketPath != null,
    port: port,
    database: database,
    username: username,
    password: password,
  );

  @override
  Stream<String> listen(String channel) {
    pg.Connection? connection;
    StreamSubscription<String>? subscription;
    var cancelled = false;
    late final StreamController<String> out;
    out = StreamController<String>(
      onListen: () async {
        try {
          final opened = connection = await pg.Connection.open(
            _endpoint,
            settings: pg.ConnectionSettings(
              sslMode: switch (sslMode) {
                .disable => pg.SslMode.disable,
                .require => pg.SslMode.require,
                .verifyFull => pg.SslMode.verifyFull,
              },
              connectTimeout: connectTimeout,
              applicationName: applicationName,
            ),
          );
          if (cancelled) {
            // The listener left during the handshake (a client that
            // disconnected at once): onCancel found nothing to close, and
            // this dedicated backend would have lived until process exit.
            connection = null;
            await opened.close(force: true);
            return;
          }
          subscription = opened.channels[channel].listen(
            out.add,
            onError: out.addError,
            onDone: out.close,
          );
        } catch (error, stackTrace) {
          out.addError(error, stackTrace);
          await out.close();
        }
      },
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
        await connection?.close();
      },
    );
    return out.stream;
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
        // package:postgres sends an untyped Infinity as the SQL literal
        // `'infinity'`, quotes included, which PostgreSQL rejects; a typed
        // float8 goes out in binary, where Infinity and NaN are plain values.
        double() when !value.isFinite => pg.TypedValue(pg.Type.double, value),
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
