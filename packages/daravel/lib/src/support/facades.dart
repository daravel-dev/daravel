import 'dart:async';

import '../database/database_manager.dart';
import '../database/query/query_ast.dart';
import '../database/query/query_builder.dart';
import '../database/query_executor.dart';
import '../database/schema/blueprint.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/locale.dart';
import '../foundation/application.dart';
import '../foundation/config.dart';
import '../foundation/container.dart';
import '../foundation/env.dart';
import '../logging/logger.dart';

/// Container access.
abstract final class App {
  /// The container of the current request, job or command.
  static Container get container => Container.current;

  /// The application.
  static Application get instance => Container.current.make<Application>();

  /// Resolves [T] (the binding [name] when given) from the container.
  static T make<T extends Object>({String? name}) =>
      Container.current.make<T>(name: name);

  /// Resolves [T], or null when it is not bound.
  static T? tryMake<T extends Object>({String? name}) =>
      Container.current.tryMake<T>(name: name);

  /// The locale of the current request, job or command (`APP_LOCALE` unless
  /// [setLocale] or `SetLocaleMiddleware` chose another).
  static String get locale => currentLocale();

  /// Sets the locale for the rest of the current scope (Laravel's
  /// `App::setLocale`).
  static void setLocale(String locale) => setCurrentLocale(locale);

  /// Whether the current locale is [locale].
  static bool isLocale(String locale) => currentLocale() == locale;
}

/// Resolves [T] from the active container (Laravel's `resolve()`), with [T]
/// inferred from where the value goes, so a default stays mockable:
///
/// ```dart
/// final class OrderController {
///   OrderController({OrderService? orders}) : orders = orders ?? inject();
///   final OrderService orders;
/// }
/// ```
///
/// Request-scoped services resolve to the current request's instance.
T inject<T extends Object>({String? name}) =>
    Container.current.make<T>(name: name);

/// [inject], or `null` when nothing is bound for [T].
T? maybeInject<T extends Object>({String? name}) =>
    Container.current.tryMake<T>(name: name);

/// Configuration access (`Config.get('app.name')`).
abstract final class Config {
  /// The configuration of the current container.
  static ConfigRepository get repository =>
      Container.current.make<ConfigRepository>();

  /// The value at the dotted [key], or [fallback].
  static T get<T>(String key, [T? fallback]) =>
      repository.get<T>(key, fallback);

  /// Whether [key] is set.
  static bool has(String key) => repository.has(key);

  /// The typed configuration section [T].
  static T section<T extends ConfigSection>() => repository.section<T>();
}

/// Logging access.
abstract final class Log {
  /// The logger of the current container.
  static Logger get logger => Container.current.make<Logger>();

  /// A named channel (`Log::channel('daily')`).
  static Logger channel(String name) => logger.channelNamed(name);

  /// Adds context to the current request/job (or shares it globally).
  static void withContext(Map<String, Object?> context) =>
      logger.withContext(context);

  /// Adds [context] to every log entry of the process (Laravel's
  /// `Log::shareContext`).
  static void shareContext(Map<String, Object?> context) =>
      logger.shareContext(context);

  /// Logs a normal but significant event.
  static void notice(String message, [Map<String, Object?>? context]) =>
      logger.notice(message, context);

  /// Captures records for assertions (`Log::spy()`); remove with
  /// `Log.logger.removeHandler(spy)`.
  static MemoryHandler spy() {
    final handler = MemoryHandler();
    logger.addHandler(handler);
    return handler;
  }

  /// Logs debugging detail.
  static void debug(String message, [Map<String, Object?>? context]) =>
      logger.debug(message, context);

  /// Logs an interesting event.
  static void info(String message, [Map<String, Object?>? context]) =>
      logger.info(message, context);

  /// Logs an exceptional occurrence that is not an error.
  static void warning(String message, [Map<String, Object?>? context]) =>
      logger.warning(message, context);

  /// Logs a runtime error, with the exception and stack trace when given.
  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => logger.error(
    message,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );
}

/// Database access.
abstract final class DB {
  /// The database manager of the current container.
  static DatabaseManager get manager =>
      Container.current.make<DatabaseManager>();

  /// The connection [name], or the default one.
  static Future<DatabaseDriver> connection([String? name]) =>
      manager.connection(name);

  /// Fluent query on [table] (`DB::table()`).
  static QueryBuilder table(String table, {String? connection}) =>
      manager.table(table, connection: connection);

  /// Raw SQL expression for use inside the query builder.
  static RawExpression raw(String sql, [List<Object?> bindings = const []]) =>
      RawExpression(sql, bindings);

  /// Raw query; [bindings] is a `List` for `?` or a `Map` for `:name`.
  static Future<List<Map<String, Object?>>> select(
    String sql, [
    Object? bindings = const <Object?>[],
  ]) => manager.select(sql, bindings);

  /// Runs a statement that returns no rows and gives the affected count.
  static Future<int> statement(
    String sql, [
    Object? bindings = const <Object?>[],
  ]) => manager.statement(sql, bindings);

  /// Runs an insert and returns the generated id.
  static Future<Object?> insertGetId(
    String sql, [
    Object? bindings = const <Object?>[],
  ]) => manager.insertGetId(sql, bindings);

  /// Runs the callback in a transaction: committed when it returns, rolled
  /// back when it throws; nested calls become savepoints, and `attempts`
  /// retries deadlocks; past `timeout` it rolls back and throws
  /// [TransactionTimeoutException] ([DatabaseManager.transaction]).
  static Future<T> transaction<T>(
    Future<T> Function() body, {
    String? connection,
    int attempts = 1,
    Duration? timeout,
  }) => manager.transaction<T>(
    body,
    connection: connection,
    attempts: attempts,
    timeout: timeout,
  );

  /// Whether the current zone is inside a transaction.
  static bool get inTransaction => manager.inTransaction;

  /// Runs [callback] if the active transaction level rolls back
  /// (`DB::afterRollBack`, [DatabaseManager.afterRollback]); nothing
  /// outside a transaction.
  static void afterRollback(FutureOr<void> Function() callback) =>
      manager.afterRollback(callback);

  /// Calls [listener] after every query (`DB::listen`): SQL, bindings,
  /// duration and connection, for debugging and slow-query logging.
  /// Register it once (in a provider); the returned function removes it.
  static void Function() listen(void Function(QueryExecuted event) listener) =>
      manager.listen(listener);

  /// Calls [listener] when a transaction begins, commits and rolls back;
  /// the returned function removes it.
  static void Function() listenTransactions(
    void Function(TransactionEvent event) listener,
  ) => manager.listenTransactions(listener);

  /// Calls [handler] once the current request, job or command has spent
  /// more than [threshold] in queries (`DB::whenQueryingForLongerThan`);
  /// the returned function removes it.
  static void Function() whenQueryingForLongerThan(
    Duration threshold,
    void Function(QueryExecuted event) handler,
  ) => manager.whenQueryingForLongerThan(threshold, handler);

  /// Time the current request, job or command has spent in queries.
  static Duration get totalQueryDuration => manager.totalQueryDuration;

  /// Runs [body] and returns its result, how many queries it ran and the
  /// queries themselves:
  ///
  /// ```dart
  /// final (users, count, _) = await DB.withQueryCount(
  ///   () => User.query().with_('posts').get(),
  /// );
  /// expect(count, 2); // eager loading: no N+1
  /// ```
  static Future<(T, int, List<QueryExecuted>)> withQueryCount<T>(
    FutureOr<T> Function() body,
  ) async {
    final (result, queries) = await manager.captureQueries(body);
    return (result, queries.length, queries);
  }
}

/// Schema access.
abstract final class Schema {
  /// The schema builder of the connection.
  static Future<SchemaBuilder> builder([String? connection]) async =>
      SchemaBuilder(await DB.manager.executor(connection));

  /// Creates a table: `Schema.create('posts', (table) { table.id(); })`.
  static Future<void> create(
    String table,
    void Function(Blueprint table) define,
  ) async => (await builder()).create(table, define);

  /// Drops [table] when it exists.
  static Future<void> dropIfExists(String table) async =>
      (await builder()).dropIfExists(table);

  /// Creates the `pgvector` extension.
  static Future<void> ensureVectorExtensionExists({String? schema}) async =>
      (await builder()).ensureVectorExtensionExists(schema: schema);

  /// Columns of [table] (`Schema::getColumns`).
  static Future<List<ColumnInfo>> getColumns(String table) async =>
      (await builder()).getColumns(table);

  /// Whether [table] exists.
  static Future<bool> hasTable(String table) async =>
      (await builder()).hasTable(table);

  /// Whether the view [view] exists.
  static Future<bool> hasView(String view) async =>
      (await builder()).hasView(view);

  /// Changes an existing table.
  static Future<void> table(
    String table,
    void Function(Blueprint table) define,
  ) async => (await builder()).table(table, define);

  /// Whether [table] has [column].
  static Future<bool> hasColumn(String table, String column) async =>
      (await builder()).hasColumn(table, column);

  /// Drops [table].
  static Future<void> drop(String table) async => (await builder()).drop(table);

  /// Renames the table [from] to [to].
  static Future<void> rename(String from, String to) async =>
      (await builder()).rename(from, to);
}

/// Reads an environment variable from the active application.
String? env(String key, [String? fallback]) =>
    Container.current.make<Env>().maybeString(key) ?? fallback;
