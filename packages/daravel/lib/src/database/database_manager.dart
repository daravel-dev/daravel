import 'dart:async';

import '../foundation/exceptions.dart';
import '../logging/logger.dart';
import 'database_config.dart';
import 'postgres_driver.dart';
import 'query/query_ast.dart';
import 'query/query_builder.dart';
import 'query/query_grammar.dart';
import 'query_executor.dart';
import 'sql_bindings.dart';
import 'sqlite_driver.dart';

/// Manages named connections, Zone-aware transactions with savepoints and
/// raw SQL binding expansion (BLUEPRINT_V2 §5.6, ADR-005).
///
/// `DB.transaction(() async { ... })` stores the transaction executor in a
/// child zone; every query issued inside the callback — directly, via the
/// query builder, models or validation rules — resolves [executor] and
/// therefore joins the transaction without passing it around explicitly.
/// Nested calls create savepoints.
final class DatabaseManager {
  DatabaseManager(this.config, {this._logger});

  /// Zone key under which the active transaction executor is stored.
  static const Symbol transactionKey = #daravel.tx;

  /// Zone key holding the after-commit callbacks of the active transaction.
  static const Object afterCommitKey = #daravelAfterCommit;

  /// Zone key marking the callbacks list of a test baseline transaction.
  static const Object baselineKey = #daravelBaselineTransaction;

  /// Zone key tracking the savepoint depth of the active transaction.
  static const Symbol depthKey = #daravel.txDepth;

  final DatabaseConfig config;
  final Logger? _logger;
  final Map<String, DatabaseDriver> _connections = <String, DatabaseDriver>{};
  final Map<String, Future<DatabaseDriver>> _connecting =
      <String, Future<DatabaseDriver>>{};

  /// Returns the (lazily connected) driver for [name] or the default
  /// connection.
  Future<DatabaseDriver> connection([String? name]) {
    final connectionName = name ?? config.defaultConnection;
    final existing = _connections[connectionName];
    if (existing != null) {
      return Future<DatabaseDriver>.value(existing);
    }
    final pending = _connecting[connectionName];
    if (pending != null) {
      return pending;
    }
    final future = () async {
      final driver = _createDriver(connectionName);
      try {
        await driver.connect();
        _connections[connectionName] = driver;
        _logger?.debug('Database connection [$connectionName] opened.');
        return driver;
      } finally {
        unawaited(_connecting.remove(connectionName));
      }
    }();
    _connecting[connectionName] = future;
    return future;
  }

  final List<void Function(QueryExecuted event)> _queryListeners =
      <void Function(QueryExecuted event)>[];

  /// Calls [listener] after every query (`DB::listen`). Listeners run
  /// synchronously on the query's isolate; keep them cheap.
  void listen(void Function(QueryExecuted event) listener) =>
      _queryListeners.add(listener);

  /// Removes every query listener.
  void forgetListeners() => _queryListeners.clear();

  /// The active transaction executor of the current zone, or the connection.
  /// With query listeners registered it is wrapped to report each query.
  Future<QueryExecutor> executor([String? name]) {
    final active = Zone.current[transactionKey] as QueryExecutor?;
    final connectionName = name ?? config.defaultConnection;
    if (active != null) {
      return Future<QueryExecutor>.value(_observed(active, connectionName));
    }
    if (_queryListeners.isEmpty) {
      return connection(name);
    }
    return connection(name)
        .then((executor) => _observed(executor, connectionName));
  }

  QueryExecutor _observed(QueryExecutor executor, String connectionName) =>
      _queryListeners.isEmpty || executor is ListeningQueryExecutor
      ? executor
      : ListeningQueryExecutor(executor, connectionName, _queryListeners);

  /// Whether the current zone is inside a transaction.
  bool get inTransaction => Zone.current[transactionKey] != null;

  /// Current savepoint depth (0 outside, 1 in the outer transaction).
  int get transactionDepth => Zone.current[depthKey] as int? ?? 0;

  /// Dialect of [name] (or the default connection) without connecting.
  SqlDialect dialectOf([String? name]) {
    final connection = config.connections[name ?? config.defaultConnection];
    if (connection == null) {
      throw ConfigException(
        'Database connection [${name ?? config.defaultConnection}] is not configured.',
      );
    }
    return switch (connection.driver) {
      'sqlite' => SqlDialect.sqlite,
      'pgsql' || 'postgres' || 'postgresql' => SqlDialect.postgres,
      'mysql' || 'mariadb' => SqlDialect.mysql,
      final other => throw UnsupportedError(
        'Unknown database driver [$other].',
      ),
    };
  }

  /// Query grammar for [name] (or the default connection).
  QueryGrammar grammarFor([String? name]) =>
      QueryGrammar.forDialect(dialectOf(name));

  /// Starts a fluent query on [table].
  QueryBuilder table(String table, {String? connection}) =>
      QueryBuilder(this, table, connection: connection);

  /// A raw SQL expression (never bound; use `?` for embedded bindings).
  RawExpression raw(String sql, [List<Object?> bindings = const []]) =>
      RawExpression(sql, bindings);

  /// Runs a raw query. [bindings] may be a `List` (`?` placeholders) or a
  /// `Map` (`:name` placeholders); see [SqlBindings].
  Future<List<Map<String, Object?>>> select(
    String sql, [
    Object? bindings = const <Object?>[],
    String? connection,
  ]) async {
    final executor = await this.executor(connection);
    final (expanded, values) = _expand(sql, bindings, executor.dialect);
    return executor.select(expanded, values);
  }

  /// Runs a raw statement and returns the affected row count.
  Future<int> statement(
    String sql, [
    Object? bindings = const <Object?>[],
    String? connection,
  ]) async {
    final executor = await this.executor(connection);
    final (expanded, values) = _expand(sql, bindings, executor.dialect);
    return executor.execute(expanded, values);
  }

  /// Runs a raw insert and returns the generated id.
  Future<Object?> insertGetId(
    String sql, [
    Object? bindings = const <Object?>[],
    String? connection,
  ]) async {
    final executor = await this.executor(connection);
    final (expanded, values) = _expand(sql, bindings, executor.dialect);
    return executor.insertGetId(expanded, values);
  }

  (String, List<Object?>) _expand(
    String sql,
    Object? bindings,
    SqlDialect dialect,
  ) {
    final grammar = QueryGrammar.forDialect(dialect);
    return SqlBindings.expand(
      sql,
      bindings ?? const <Object?>[],
      grammar.parameter,
    );
  }

  /// Runs [body] in a transaction on [connection] (default when `null`).
  /// Nested calls create a savepoint that is released or rolled back with
  /// the nested callback. With [attempts] > 1, deadlocks and serialization
  /// failures retry the whole transaction.
  Future<T> transaction<T>(
    Future<T> Function() body, {
    String? connection,
    int attempts = 1,
  }) async {
    if (inTransaction) {
      return _savepoint(body);
    }
    final driver = await this.connection(connection);
    for (var attempt = 1; ; attempt++) {
      final callbacks = <FutureOr<void> Function()>[];
      try {
        final result = await driver.transaction<T>(
          (tx) => runZoned<Future<T>>(
            body,
            zoneValues: <Object?, Object?>{
              transactionKey: tx,
              depthKey: 1,
              afterCommitKey: callbacks,
            },
          ),
        );
        for (final callback in callbacks) {
          await callback();
        }
        return result;
      } catch (error) {
        if (attempt >= attempts || !_isRetryable(error)) {
          rethrow;
        }
        _logger?.warning(
          'Transaction attempt $attempt failed with a retryable error; retrying.',
        );
      }
    }
  }

  Future<T> _savepoint<T>(Future<T> Function() body) async {
    final tx = Zone.current[transactionKey]! as QueryExecutor;
    final depth = transactionDepth + 1;
    final name = 'daravel_sp_$depth';
    final callbacks = <FutureOr<void> Function()>[];
    await tx.execute('SAVEPOINT $name');
    try {
      final result = await runZoned<Future<T>>(
        body,
        zoneValues: <Object?, Object?>{
          depthKey: depth,
          afterCommitKey: callbacks,
        },
      );
      await tx.execute('RELEASE SAVEPOINT $name');
      final parent =
          Zone.current[afterCommitKey] as List<FutureOr<void> Function()>?;
      if (parent != null && identical(parent, Zone.current[baselineKey])) {
        // The app-level transaction "committed" inside a test baseline.
        for (final callback in callbacks) {
          await callback();
        }
      } else {
        parent?.addAll(callbacks);
      }
      return result;
    } catch (_) {
      await tx.execute('ROLLBACK TO SAVEPOINT $name');
      rethrow;
    }
  }

  /// Runs [callback] once the active transaction (and its savepoints)
  /// commits; a rollback discards it. Outside a transaction it runs now.
  Future<void> afterCommit(FutureOr<void> Function() callback) async {
    final pending =
        Zone.current[afterCommitKey] as List<FutureOr<void> Function()>?;
    if (pending == null ||
        !inTransaction ||
        identical(pending, Zone.current[baselineKey])) {
      await callback();
      return;
    }
    pending.add(callback);
  }

  /// Runs [body] in a transaction that is always rolled back (Laravel
  /// `RefreshDatabase`). Application transactions inside become savepoints
  /// and their after-commit callbacks fire when they "commit", as they
  /// would without the wrapper.
  Future<T> rollbackAfter<T>(
    Future<T> Function() body, {
    String? connection,
  }) async {
    if (inTransaction) {
      throw StateError('rollbackAfter cannot be nested inside a transaction.');
    }
    final driver = await this.connection(connection);
    final baseline = <FutureOr<void> Function()>[];
    late T result;
    try {
      await driver.transaction<void>(
        (tx) => runZoned<Future<void>>(
          () async {
            result = await body();
            throw const _RollbackSignal();
          },
          zoneValues: <Object?, Object?>{
            transactionKey: tx,
            depthKey: 1,
            afterCommitKey: baseline,
            baselineKey: baseline,
          },
        ),
      );
    } on _RollbackSignal {
      return result;
    }
    return result;
  }

  static bool _isRetryable(Object error) => PostgresDriver.isRetryable(error);

  /// Whether any connection has been opened.
  bool get hasOpenConnections => _connections.isNotEmpty;

  /// Closes every open connection.
  Future<void> closeAll() async {
    final drivers = List<DatabaseDriver>.of(_connections.values);
    _connections.clear();
    for (final driver in drivers) {
      await driver.close();
      _logger?.debug('Database connection [${driver.name}] closed.');
    }
  }

  DatabaseDriver _createDriver(String name) {
    final connection = config.connections[name];
    if (connection == null) {
      throw ConfigException('Database connection [$name] is not configured.');
    }
    switch (connection.driver) {
      case 'sqlite':
        return SqliteDriver(path: connection.database, name: name);
      case 'pgsql':
      case 'postgres':
      case 'postgresql':
        return PostgresDriver(
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
        );
      default:
        throw UnsupportedError(
          'Database driver [${connection.driver}] is not available yet '
          '(MySQL/MariaDB arrives in slice S5b).',
        );
    }
  }
}

/// Internal: forces [DatabaseManager.rollbackAfter] to roll back.
final class _RollbackSignal implements Exception {
  const _RollbackSignal();
}
