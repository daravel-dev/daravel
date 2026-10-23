import 'dart:async';

import '../foundation/exceptions.dart';
import '../logging/logger.dart';
import 'database_config.dart';
import 'query_executor.dart';
import 'sqlite_driver.dart';

/// Manages named connections and Zone-aware transactions (BLUEPRINT_V2 §5.6).
///
/// `DB.transaction(() async { ... })` stores the transaction executor in a
/// child zone; every query issued inside the callback — directly, via models
/// or via validation rules — resolves [executor] and therefore joins the
/// transaction without passing it around explicitly.
final class DatabaseManager {
  DatabaseManager(this.config, {Logger? logger}) : _logger = logger;

  /// Zone key under which the active transaction executor is stored.
  static const Symbol transactionKey = #daravel.tx;

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

  /// The active transaction executor of the current zone, or the connection.
  Future<QueryExecutor> executor([String? name]) {
    final active = Zone.current[transactionKey] as QueryExecutor?;
    if (active != null) {
      return Future<QueryExecutor>.value(active);
    }
    return connection(name);
  }

  /// Whether the current zone is inside a transaction.
  bool get inTransaction => Zone.current[transactionKey] != null;

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async => (await executor()).select(sql, bindings);

  Future<int> statement(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async => (await executor()).execute(sql, bindings);

  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) async => (await executor()).insertGetId(sql, bindings);

  /// Runs [body] in a transaction on [connection] (default when `null`).
  /// Nested calls join the enclosing transaction (savepoints arrive in S5).
  Future<T> transaction<T>(
    Future<T> Function() body, {
    String? connection,
  }) async {
    if (inTransaction) {
      return body();
    }
    final driver = await this.connection(connection);
    return driver.transaction<T>(
      (tx) => runZoned<Future<T>>(
        body,
        zoneValues: <Object?, Object?>{transactionKey: tx},
      ),
    );
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
    switch (connection.driver) {
      case 'sqlite':
        return SqliteDriver(path: connection.database, name: name);
      default:
        throw UnsupportedError(
          'Database driver [${connection.driver}] is not available yet '
          '(Tier 0 ships SQLite; PostgreSQL and MySQL arrive in slice S5).',
        );
    }
  }
}
