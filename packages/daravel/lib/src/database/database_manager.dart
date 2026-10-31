import 'dart:async';
import 'dart:math' as math;

import '../foundation/clock.dart';
import '../foundation/container.dart';
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
/// Builds the driver of a connection whose `driver` is not built in
/// (`mysql` and `mariadb` come from package:daravel_mysql).
typedef DatabaseDriverFactory = DatabaseDriver Function(
  String name,
  ConnectionConfig connection,
);

final class DatabaseManager {
  DatabaseManager(
    this.config, {
    this._logger,
    Map<String, DatabaseDriverFactory> drivers = const {},
  }) : _driverFactories = drivers;

  final Map<String, DatabaseDriverFactory> _driverFactories;

  /// Zone key under which the active transaction executor is stored.
  static const Symbol transactionKey = #daravel.tx;

  /// Zone key holding the after-commit callbacks of the active transaction.
  static const Object afterCommitKey = #daravelAfterCommit;

  /// Zone key marking the callbacks list of a test baseline transaction.
  static const Object baselineKey = #daravelBaselineTransaction;

  /// Zone key tracking the savepoint depth of the active transaction.
  static const Symbol depthKey = #daravel.txDepth;

  /// Zone key of the active transaction level (its lock and executor).
  static const Symbol _scopeKey = #daravel.txScope;

  final DatabaseConfig config;
  final Logger? _logger;
  final Map<String, DatabaseDriver> _connections = <String, DatabaseDriver>{};
  final Map<String, Future<DatabaseDriver>> _connecting =
      <String, Future<DatabaseDriver>>{};

  /// A separate manager whose only (and default) connection is [connection]
  /// under [name], with this manager's registered drivers: for tools that
  /// reach a database outside the configuration (`dartisan db:transfer`).
  /// Close it with [closeAll].
  DatabaseManager forConnection(String name, ConnectionConfig connection) =>
      DatabaseManager(
        DatabaseConfig(
          defaultConnection: name,
          connections: <String, ConnectionConfig>{name: connection},
        ),
        logger: _logger,
        drivers: _driverFactories,
      );

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

  static const Symbol _captureKey = #daravel.queryCapture;

  /// Runs [body] and returns its result with every query it ran, in this
  /// zone (nested calls each see their own queries): for tests that assert
  /// eager loading removed an N+1.
  Future<(T, List<QueryExecuted>)> captureQueries<T>(
    FutureOr<T> Function() body,
  ) async {
    final captured = <QueryExecuted>[];
    final outer = Zone.current[_captureKey] as List<List<QueryExecuted>>?;
    final result = await runZoned(
      () async => body(),
      zoneValues: {
        _captureKey: [...?outer, captured],
      },
    );
    return (result, captured);
  }

  final List<(Duration, void Function(QueryExecuted event))> _durationHandlers =
      [];
  final _QueryTime _isolateQueryTime = _QueryTime();

  /// Calls [handler] once the queries of the current request, job or
  /// command have taken more than [threshold] in total (Laravel's
  /// `DB::whenQueryingForLongerThan`), once per scope.
  void whenQueryingForLongerThan(
    Duration threshold,
    void Function(QueryExecuted event) handler,
  ) => _durationHandlers.add((threshold, handler));

  /// Time spent in queries by the current request, job or command (the
  /// isolate's total outside a scope).
  Duration get totalQueryDuration => _queryTime().total;

  _QueryTime _queryTime() {
    final Scope? scope;
    try {
      scope = Container.current.currentScope;
    } on StateError {
      return _isolateQueryTime;
    }
    if (scope == null) {
      return _isolateQueryTime;
    }
    final existing = scope.get<_QueryTime>();
    if (existing != null) {
      return existing;
    }
    final time = _QueryTime();
    scope.put<_QueryTime>(time);
    return time;
  }

  /// Reports [event] to listeners, captures and duration handlers. Runs in
  /// the zone of the query.
  void _dispatch(QueryExecuted event) {
    for (final listener in List.of(_queryListeners)) {
      listener(event);
    }
    final captures = Zone.current[_captureKey] as List<List<QueryExecuted>>?;
    if (captures != null) {
      for (final captured in captures) {
        captured.add(event);
      }
    }
    if (_durationHandlers.isNotEmpty) {
      final time = _queryTime()..total += event.time;
      for (var i = 0; i < _durationHandlers.length; i++) {
        final (threshold, handler) = _durationHandlers[i];
        if (time.total > threshold && time.fired.add(i)) {
          handler(event);
        }
      }
    }
  }

  bool get _observing =>
      _queryListeners.isNotEmpty ||
      _durationHandlers.isNotEmpty ||
      Zone.current[_captureKey] != null;

  /// The active transaction executor of the current zone, or the connection.
  /// While anything listens (listeners, captures, duration handlers) it is
  /// wrapped to report each query.
  Future<QueryExecutor> executor([String? name]) {
    final active = _activeScope(name)?.executor;
    final connectionName = name ?? config.defaultConnection;
    if (active != null) {
      return Future<QueryExecutor>.value(
        _guarded(_observed(active, connectionName), connectionName),
      );
    }
    return connection(name).then(
      (executor) =>
          _guarded(_observed(executor, connectionName), connectionName),
    );
  }

  /// [executor] turning driver errors into [QueryException]s.
  QueryExecutor _guarded(QueryExecutor executor, String connectionName) =>
      executor is QueryExceptionExecutor
      ? executor
      : QueryExceptionExecutor(
          executor,
          connectionName,
          switch (_connections[connectionName]) {
            final QueryErrors errors => errors,
            _ => null,
          },
        );

  QueryExecutor _observed(QueryExecutor executor, String connectionName) =>
      !_observing || executor is ListeningQueryExecutor
      ? executor
      : ListeningQueryExecutor(executor, connectionName, [_dispatch]);

  /// Whether the current zone is inside a transaction on the default
  /// connection of this manager.
  bool get inTransaction => _activeScope(null) != null;

  /// Whether the current zone is inside a transaction on [connection] (the
  /// default connection when `null`).
  bool inTransactionOn([String? connection]) =>
      _activeScope(connection) != null;

  /// The transaction of the current zone when it runs on [name] (the
  /// default connection when `null`) of this manager.
  _TransactionScope? _activeScope(String? name) {
    final scope = Zone.current[_scopeKey];
    return scope is _TransactionScope &&
            identical(scope.owner, this) &&
            scope.connectionName == (name ?? config.defaultConnection)
        ? scope
        : null;
  }

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
      'mysql' => SqlDialect.mysql,
      'mariadb' => SqlDialect.mariadb,
      final other => throw UnsupportedError(
        'Unknown database driver [$other].',
      ),
    };
  }

  /// Query grammar for [name] (or the default connection).
  QueryGrammar grammarFor([String? name]) =>
      QueryGrammar.forDialect(dialectOf(name));

  /// Payloads sent with [notify] on [channel], when the connection delivers
  /// notifications (PostgreSQL's `LISTEN`); `null` otherwise, so callers
  /// poll instead. The stream holds a connection of its own until its
  /// listener cancels.
  Future<Stream<String>?> notifications(
    String channel, {
    String? connection,
  }) async {
    final driver = await this.connection(connection);
    return driver is NotifyingDriver ? driver.listen(channel) : null;
  }

  /// Wakes the [notifications] listeners of [channel], on every machine
  /// connected to the database (PostgreSQL's `NOTIFY`; inside a transaction
  /// it is sent at commit). Nothing on databases without notifications.
  Future<void> notify(
    String channel, [
    String payload = '',
    String? connection,
  ]) async {
    if (dialectOf(connection) == .postgres) {
      await select('SELECT pg_notify(?, ?)', [channel, payload], connection);
    }
  }

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

  static const Duration retryBaseDelay = Duration(milliseconds: 2);
  static const Duration retryMaxDelay = Duration(milliseconds: 250);
  static final math.Random _retryRandom = math.Random();

  /// The next wait of a retry, decorrelated jitter: anywhere from the base
  /// to three times [previous]. Fifty isolates that collided do not collide
  /// again on the same microsecond.
  static Duration retryDelay(Duration previous, math.Random random) {
    final base = retryBaseDelay.inMicroseconds;
    final span = previous.inMicroseconds * 3 - base;
    final next = base + random.nextInt(span < 1 ? 1 : span);
    return Duration(
      microseconds: next < retryMaxDelay.inMicroseconds
          ? next
          : retryMaxDelay.inMicroseconds,
    );
  }

  /// Runs [body] in a transaction on [connection] (default when `null`).
  /// Nested calls create a savepoint that is released or rolled back with
  /// the nested callback. With [attempts] > 1, deadlocks and serialization
  /// failures retry the whole transaction, after a short random wait.
  Future<T> transaction<T>(
    Future<T> Function() body, {
    String? connection,
    int attempts = 1,
  }) async {
    if (_activeScope(connection) != null) {
      return _savepoint(body);
    }
    final connectionName = connection ?? config.defaultConnection;
    final driver = await this.connection(connection);
    var wait = retryBaseDelay;
    for (var attempt = 1; ; attempt++) {
      final callbacks = <FutureOr<void> Function()>[];
      final T result;
      try {
        result = await driver.transaction<T>((tx) {
          final scope = _TransactionScope(tx, this, connectionName);
          return runZoned<Future<T>>(
            body,
            zoneValues: <Object?, Object?>{
              transactionKey: scope.executor,
              _scopeKey: scope,
              depthKey: 1,
              afterCommitKey: callbacks,
            },
          ).whenComplete(scope.close);
        });
      } catch (error) {
        if (attempt >= attempts || !_isRetryable(driver, error)) {
          rethrow;
        }
        _logger?.warning(
          'Transaction attempt $attempt failed with a retryable error; retrying.',
        );
        // Wall clock: a frozen test clock must not slow the retry, and a
        // delay needs no connection, so the others get theirs meanwhile.
        if (!Clock.isFaked) {
          wait = retryDelay(wait, _retryRandom);
          await Future<void>.delayed(wait);
        }
        continue;
      }
      // Committed. The callbacks run outside the retry above: one that
      // fails with a deadlock or busy error (a query of its own) must not
      // run the body, and its writes, a second time. As in Laravel, the
      // first callback to throw stops the rest and surfaces to the caller.
      for (final callback in callbacks) {
        await callback();
      }
      return result;
    }
  }

  /// A savepoint under the current level. Savepoints on one connection form
  /// a stack, so siblings started together (`Future.wait`) run one after
  /// another; each gets its own scope for its own children.
  Future<T> _savepoint<T>(Future<T> Function() body) {
    final parent = Zone.current[_scopeKey]! as _TransactionScope;
    return parent.runChild(() async {
      final tx = parent.connection;
      final depth = transactionDepth + 1;
      final name = 'daravel_sp_$depth';
      final callbacks = <FutureOr<void> Function()>[];
      final scope = _TransactionScope(tx, this, parent.connectionName);
      await tx.execute('SAVEPOINT $name');
      try {
        final result = await runZoned<Future<T>>(
          body,
          zoneValues: <Object?, Object?>{
            transactionKey: scope.executor,
            _scopeKey: scope,
            depthKey: depth,
            afterCommitKey: callbacks,
          },
        );
        scope.close();
        await tx.execute('RELEASE SAVEPOINT $name');
        final pending =
            Zone.current[afterCommitKey] as List<FutureOr<void> Function()>?;
        if (pending != null && identical(pending, Zone.current[baselineKey])) {
          // The app-level transaction "committed" inside a test baseline.
          for (final callback in callbacks) {
            await callback();
          }
        } else {
          pending?.addAll(callbacks);
        }
        return result;
      } catch (_) {
        scope.close();
        await tx.execute('ROLLBACK TO SAVEPOINT $name');
        rethrow;
      }
    });
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
    if (_activeScope(connection) != null) {
      throw StateError('rollbackAfter cannot be nested inside a transaction.');
    }
    final connectionName = connection ?? config.defaultConnection;
    final driver = await this.connection(connection);
    final baseline = <FutureOr<void> Function()>[];
    late T result;
    try {
      await driver.transaction<void>((tx) {
        final scope = _TransactionScope(tx, this, connectionName);
        return runZoned<Future<void>>(
          () async {
            result = await body();
            throw const _RollbackSignal();
          },
          zoneValues: <Object?, Object?>{
            transactionKey: scope.executor,
            _scopeKey: scope,
            depthKey: 1,
            afterCommitKey: baseline,
            baselineKey: baseline,
          },
        ).whenComplete(scope.close);
      });
    } on _RollbackSignal {
      return result;
    }
    return result;
  }

  static bool _isRetryable(DatabaseDriver driver, Object error) {
    // A statement's error arrives wrapped; the driver knows its own.
    final cause = error is QueryException ? error.previous : error;
    return PostgresDriver.isRetryable(cause) ||
        switch (driver) {
          final RetryableErrors retryable => retryable.isRetryableError(cause),
          _ => false,
        };
  }

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
    final custom = _driverFactories[connection.driver];
    if (custom != null) {
      return custom(name, connection);
    }
    switch (connection.driver) {
      // Built in through 1.x; in 2.0 they move to package:daravel_sqlite
      // and package:daravel_postgres and are registered like MySQL.
      case 'sqlite':
        return SqliteDriver.fromConfig(name, connection);
      case 'pgsql':
      case 'postgres':
      case 'postgresql':
        return PostgresDriver.fromConfig(name, connection);
      case 'mysql' || 'mariadb':
        throw UnsupportedError(
          'The ${connection.driver} driver is in package:daravel_mysql: add '
          'it to pubspec.yaml and register it in bootstrap/app.dart with '
          ".withDatabaseDriver('${connection.driver}', MySqlDriver.fromConfig).",
        );
      default:
        throw UnsupportedError(
          'Database driver [${connection.driver}] is not available; register '
          'one with ApplicationBuilder.withDatabaseDriver.',
        );
    }
  }
}

/// Internal: forces [DatabaseManager.rollbackAfter] to roll back.
final class _RollbackSignal implements Exception {
  const _RollbackSignal();
}

/// One transaction or savepoint level on a [connection].
///
/// Its [executor] (what the zone hands to queries) stops working when the
/// level ends, so a query that outlives it (a missing `await`) fails
/// instead of running outside the transaction. Child savepoints run one at
/// a time ([runChild]), and queries of this level wait while a child is
/// open, so none lands inside a savepoint that is then rolled back.
final class _TransactionScope {
  _TransactionScope(this.connection, this.owner, this.connectionName) {
    executor = _ScopedExecutor(this);
  }

  /// The driver's transaction executor (shared by every level).
  final QueryExecutor connection;

  /// The manager and connection the transaction runs on: queries of
  /// another connection (or another manager) never join it.
  final DatabaseManager owner;
  final String connectionName;
  late final QueryExecutor executor;
  bool _closed = false;
  Future<void> _children = Future<void>.value();

  void close() => _closed = true;

  Future<T> runChild<T>(Future<T> Function() body) {
    final previous = _children;
    final done = Completer<void>();
    _children = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  /// Waits for open child savepoints, then checks that the level is open.
  Future<void> _ready(String sql) async {
    await _children;
    if (_closed) {
      throw StateError(
        'A query ran after its transaction finished; await every query '
        'inside DB.transaction: $sql',
      );
    }
  }
}

final class _ScopedExecutor implements QueryExecutor {
  _ScopedExecutor(this._scope);

  final _TransactionScope _scope;

  @override
  SqlDialect get dialect => _scope.connection.dialect;

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    await _scope._ready(sql);
    return _scope.connection.select(sql, bindings);
  }

  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    await _scope._ready(sql);
    return _scope.connection.execute(sql, bindings);
  }

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async {
    await _scope._ready(sql);
    return _scope.connection.insertGetId(sql, bindings);
  }
}

/// Query time of one scope, and which duration handlers already fired.
final class _QueryTime {
  Duration total = Duration.zero;
  final Set<int> fired = <int>{};
}
