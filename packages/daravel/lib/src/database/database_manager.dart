import 'dart:async';
import 'dart:math' as math;

import '../foundation/cancellation.dart';
import '../foundation/clock.dart';
import '../foundation/container.dart';
import '../foundation/detached.dart';
import '../foundation/shared_result.dart';
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

/// Opens and keeps the database connections, runs transactions
/// (nested ones as savepoints) and after-commit callbacks, and hands out
/// query builders. `DB` is its facade.
final class DatabaseManager {
  /// A manager for [config]'s connections; drivers beyond SQLite and
  /// PostgreSQL are registered through `withDatabaseDriver`.
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

  /// The connections it manages.
  final DatabaseConfig config;
  final Logger? _logger;
  final Map<String, DatabaseDriver> _connections = <String, DatabaseDriver>{};
  // Shared by the requests that ask while it opens: a SharedResult, so a
  // connection that fails to open fails every one of them (a failing
  // future would hang those waiting from another request's zone).
  final Map<String, SharedResult<DatabaseDriver>> _connecting =
      <String, SharedResult<DatabaseDriver>>{};

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

  /// The server sessions the open connections hold, by connection name, for
  /// the drivers that can end them from elsewhere
  /// ([SessionTerminatingDriver]); connections not opened yet and other
  /// drivers are left out.
  Map<String, List<String>> openSessions() => <String, List<String>>{
    for (final MapEntry(:key, :value) in _connections.entries)
      if (value case final SessionTerminatingDriver driver)
        if (driver.sessionIds() case final ids when ids.isNotEmpty) key: ids,
  };

  /// A connection in logs: its name, then its driver (`[sqlite] (pgsql)`
  /// when `DB_URL` gives the connection named `sqlite` a PostgreSQL URL).
  String _described(String name) =>
      '[$name] (${config.connections[name]?.driver ?? 'unknown'})';

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
      return pending.value;
    }
    // In a microtask, so that it is registered below before it can finish:
    // a factory that throws (a secret not there yet) ended it at once, its
    // `finally` removed nothing, and the failure stayed cached for good.
    // Detached: the connection outlives the request that opens it, and its
    // socket's listeners would live on in that request's zone (its log
    // context, its cancellation token; Review #149).
    final shared = SharedResult<DatabaseDriver>(
      () => runDetachedAsync(
        () => Future<DatabaseDriver>.microtask(() async {
          try {
            final driver = _createDriver(connectionName);
            await driver.connect();
            _connections[connectionName] = driver;
            _logger?.debug(
              'Database connection ${_described(connectionName)} opened.',
            );
            return driver;
          } finally {
            _connecting.remove(connectionName);
          }
        }),
        name: 'database connection [$connectionName]',
      ).value,
    );
    _connecting[connectionName] = shared;
    return shared.value;
  }

  // Copied on write: a query reads them without copying, and a listener
  // removed while they are being called is still called this once.
  List<void Function(QueryExecuted event)> _queryListeners =
      const <void Function(QueryExecuted event)>[];

  /// Calls [listener] after every query (`DB::listen`). Listeners run
  /// synchronously on the query's isolate; keep them cheap.
  ///
  /// Register listeners once (in a service provider's `boot`): each one
  /// runs for every query of the isolate until removed. The returned
  /// function removes this one.
  void Function() listen(void Function(QueryExecuted event) listener) {
    _queryListeners = [..._queryListeners, listener];
    return () => _queryListeners = [
      for (final other in _queryListeners)
        if (!identical(other, listener)) other,
    ];
  }

  List<void Function(TransactionEvent event)> _transactionListeners =
      const <void Function(TransactionEvent event)>[];

  /// Calls [listener] when a transaction or savepoint begins, commits and
  /// rolls back, synchronously; keep it cheap. Register it once; the
  /// returned function removes it.
  void Function() listenTransactions(
    void Function(TransactionEvent event) listener,
  ) {
    _transactionListeners = [..._transactionListeners, listener];
    return () => _transactionListeners = [
      for (final other in _transactionListeners)
        if (!identical(other, listener)) other,
    ];
  }

  void _notifyTransaction(TransactionEvent event) {
    for (final listener in _transactionListeners) {
      listener(event);
    }
  }

  /// Removes every query listener.
  void forgetListeners() =>
      _queryListeners = const <void Function(QueryExecuted event)>[];

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

  List<_DurationHandler> _durationHandlers = const <_DurationHandler>[];
  final _QueryTime _isolateQueryTime = _QueryTime();

  /// Calls [handler] once the queries of the current request, job or
  /// command have taken more than [threshold] in total (Laravel's
  /// `DB::whenQueryingForLongerThan`), once per scope. Register it once;
  /// the returned function removes it.
  void Function() whenQueryingForLongerThan(
    Duration threshold,
    void Function(QueryExecuted event) handler,
  ) {
    final entry = _DurationHandler(threshold, handler);
    _durationHandlers = [..._durationHandlers, entry];
    return () => _durationHandlers = [
      for (final other in _durationHandlers)
        if (!identical(other, entry)) other,
    ];
  }

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
    for (final listener in _queryListeners) {
      listener(event);
    }
    final captures = Zone.current[_captureKey] as List<List<QueryExecuted>>?;
    if (captures != null) {
      for (final captured in captures) {
        captured.add(event);
      }
    }
    final handlers = _durationHandlers;
    if (handlers.isNotEmpty) {
      final time = _queryTime()..total += event.time;
      for (final entry in handlers) {
        if (time.total > entry.threshold && time.fired.add(entry)) {
          entry.handler(event);
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

  /// The shortest wait before retrying a transaction that hit a deadlock.
  static const Duration retryBaseDelay = Duration(milliseconds: 2);

  /// The longest wait between retries.
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
  ///
  /// With a [timeout], a body still running when it passes is given up: its
  /// transaction (or savepoint) rolls back, the connection goes back to the
  /// pool, the call throws [TransactionTimeoutException] (not retried), and
  /// any later query of that body throws it too instead of running. A query
  /// already waiting in the database (on a row lock, say) ends only when the
  /// database lets it go, so pair this with the database's own lock timeout.
  Future<T> transaction<T>(
    Future<T> Function() body, {
    String? connection,
    int attempts = 1,
    Duration? timeout,
  }) async {
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    if (_activeScope(connection) != null) {
      return _savepoint(body, timeout);
    }
    final connectionName = connection ?? config.defaultConnection;
    final driver = await this.connection(connection);
    var wait = retryBaseDelay;
    for (var attempt = 1; ; attempt++) {
      final callbacks = <FutureOr<void> Function()>[];
      final T result;
      final probe = PoolWaitProbe();
      final watch = Stopwatch();
      final watched = _transactionListeners.isNotEmpty;
      var begun = false;
      Future<T> run() => driver.transaction<T>((tx) {
        if (watched) {
          begun = true;
          _notifyTransaction(
            DbTransactionBeginning(connectionName, 1, poolWait: probe.waited),
          );
          watch.start();
        }
        final scope = _TransactionScope(tx, this, connectionName);
        return _bounded(
          runZoned<Future<T>>(
            _unlessCancelled(body),
            zoneValues: <Object?, Object?>{
              transactionKey: scope.executor,
              _scopeKey: scope,
              depthKey: 1,
              afterCommitKey: callbacks,
            },
          ),
          timeout,
          scope,
        ).whenComplete(scope.close);
      });
      try {
        result = await (watched ? probe.run(run) : run());
        if (watched) {
          _notifyTransaction(
            DbTransactionCommitted(connectionName, 1, watch.elapsed),
          );
        }
      } catch (error) {
        // No connection, no BEGIN: nothing to pair a rollback with.
        if (begun) {
          _notifyTransaction(
            DbTransactionRolledBack(connectionName, 1, watch.elapsed, error),
          );
        }
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
  /// [work] (a transaction's body), or [TransactionTimeoutException] once
  /// [timeout] passes without it: [scope] is then closed first, so the
  /// body's later queries fail rather than run on a connection that has
  /// rolled back and gone back to the pool. The error thrown inside the
  /// driver's transaction (or the savepoint) is what rolls it back.
  static Future<T> _bounded<T>(
    Future<T> work,
    Duration? timeout,
    _TransactionScope scope,
  ) {
    if (timeout == null) {
      return work;
    }
    final done = Completer<T>();
    // A Timer, not Clock: a frozen test clock must not stop the guard.
    final timer = Timer(timeout, () {
      if (done.isCompleted) {
        return;
      }
      final error = TransactionTimeoutException(timeout);
      scope.close(error);
      done.completeError(error, StackTrace.current);
    });
    work.then(
      (value) {
        timer.cancel();
        if (!done.isCompleted) {
          done.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        timer.cancel();
        if (!done.isCompleted) {
          done.completeError(error, stack);
        }
      },
    );
    return done.future;
  }

  /// [body] between two checks of the zone's [CancellationToken]: work that
  /// was given up (a job past its timeout) neither starts a transaction nor
  /// commits one; the [OperationCancelledException] rolls it back instead.
  static Future<T> Function() _unlessCancelled<T>(Future<T> Function() body) =>
      () async {
        final token = CancellationToken.current;
        token?.throwIfCancelled();
        final result = await body();
        token?.throwIfCancelled();
        return result;
      };

  Future<T> _savepoint<T>(Future<T> Function() body, Duration? timeout) {
    final parent = Zone.current[_scopeKey]! as _TransactionScope;
    return parent.runChild(() async {
      // The level this savepoint would live in has ended (timed out, or its
      // body returned without awaiting this call): a SAVEPOINT now would
      // run outside any transaction, or in the one around it, and commit.
      parent.ensureOpen('SAVEPOINT');
      final tx = parent.connection;
      final depth = transactionDepth + 1;
      final name = 'daravel_sp_$depth';
      final callbacks = <FutureOr<void> Function()>[];
      final scope = _TransactionScope(tx, this, parent.connectionName, parent);
      try {
        await tx.execute('SAVEPOINT $name');
      } catch (_) {
        scope.close();
        rethrow;
      }
      final watch = Stopwatch()..start();
      _notifyTransaction(DbTransactionBeginning(parent.connectionName, depth));
      try {
        final result = await _bounded(
          runZoned<Future<T>>(
            _unlessCancelled(body),
            zoneValues: <Object?, Object?>{
              transactionKey: scope.executor,
              _scopeKey: scope,
              depthKey: depth,
              afterCommitKey: callbacks,
            },
          ),
          timeout,
          scope,
        );
        scope.close();
        // The parent ended while the body ran: the savepoint went with it,
        // and so did the body's writes.
        parent.ensureOpen('RELEASE SAVEPOINT');
        await tx.execute('RELEASE SAVEPOINT $name');
        _notifyTransaction(
          DbTransactionCommitted(parent.connectionName, depth, watch.elapsed),
        );
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
      } catch (error, stack) {
        scope.close();
        // A parent that ended took the savepoint with it.
        if (!parent.isClosed) {
          try {
            await tx.execute('ROLLBACK TO SAVEPOINT $name');
          } on Object catch (rollbackError) {
            // The database ended the transaction itself (SQLite on
            // SQLITE_FULL), or the connection broke: the levels above are
            // gone too, so their later queries must fail rather than run
            // outside a transaction. The body's error is still the one
            // the caller sees.
            parent.close(
              StateError(
                'The transaction can no longer be used: rolling back '
                'savepoint $name failed ($rollbackError) after: $error',
              ),
            );
          }
        }
        _notifyTransaction(
          DbTransactionRolledBack(
            parent.connectionName,
            depth,
            watch.elapsed,
            error,
          ),
        );
        Error.throwWithStackTrace(error, stack);
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

  /// How long [closeAll] waits for one connection by default.
  static const Duration closeTimeout = Duration(seconds: 10);

  /// Closes every open connection, each within [timeout]: a driver that
  /// throws or takes longer (a pool waiting for an abandoned transaction)
  /// is logged and left behind, and the others are still closed. The first
  /// error is rethrown once all were tried; a timeout is only logged.
  Future<void> closeAll({Duration timeout = closeTimeout}) async {
    final drivers = List<DatabaseDriver>.of(_connections.values);
    _connections.clear();
    (Object, StackTrace)? failure;
    for (final driver in drivers) {
      try {
        await driver.close().timeout(timeout);
        _logger?.debug(
          'Database connection ${_described(driver.name)} closed.',
        );
      } on TimeoutException {
        _logger?.warning(
          'Database connection [${driver.name}] did not close within '
          '$timeout; leaving it behind.',
        );
      } on Object catch (error, stack) {
        _logger?.warning(
          'Database connection [${driver.name}] failed to close: $error',
        );
        failure ??= (error, stack);
      }
    }
    if (failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
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
  _TransactionScope(
    this.connection,
    this.owner,
    this.connectionName, [
    this._parent,
  ]) {
    executor = _ScopedExecutor(this);
    _parent?._open.add(this);
  }

  /// The driver's transaction executor (shared by every level).
  final QueryExecutor connection;

  /// The manager and connection the transaction runs on: queries of
  /// another connection (or another manager) never join it.
  final DatabaseManager owner;
  final String connectionName;
  final _TransactionScope? _parent;
  late final QueryExecutor executor;
  bool _closed = false;
  Object? _closedBy;
  Future<void> _children = Future<void>.value();

  /// Child savepoints still open: they end with this level.
  final Set<_TransactionScope> _open = <_TransactionScope>{};

  /// Whether the level has ended.
  bool get isClosed => _closed;

  /// Closes the level and every savepoint still open under it; [error] (a
  /// timeout) is what a later query of any of them throws.
  void close([Object? error]) {
    _closedBy ??= error;
    if (_closed) {
      return;
    }
    _closed = true;
    _parent?._open.remove(this);
    for (final child in List<_TransactionScope>.of(_open)) {
      child.close(_closedBy);
    }
    _open.clear();
  }

  /// Throws when the level has ended: its timeout, or a [StateError] for
  /// [sql], a statement that outlived it.
  void ensureOpen(String sql) {
    if (_closed) {
      final closedBy = _closedBy;
      if (closedBy != null) {
        throw closedBy;
      }
      throw StateError(
        'A query ran after its transaction finished; await every query '
        'inside DB.transaction: $sql',
      );
    }
  }

  Future<T> runChild<T>(Future<T> Function() body) {
    final previous = _children;
    final done = Completer<void>();
    _children = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  /// Checks that the level is open (failing at once when it has ended),
  /// waits for open child savepoints, then checks again: the level may
  /// have ended meanwhile.
  Future<void> _ready(String sql) async {
    ensureOpen(sql);
    await _children;
    ensureOpen(sql);
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
  final Set<_DurationHandler> fired = <_DurationHandler>{};
}

/// A `whenQueryingForLongerThan` registration; its identity marks it as
/// fired in a scope.
final class _DurationHandler {
  _DurationHandler(this.threshold, this.handler);

  final Duration threshold;
  final void Function(QueryExecuted event) handler;
}
