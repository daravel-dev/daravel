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
  static Container get container => Container.current;

  static Application get instance => Container.current.make<Application>();

  static T make<T extends Object>({String? name}) =>
      Container.current.make<T>(name: name);

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
  static ConfigRepository get repository =>
      Container.current.make<ConfigRepository>();

  static T get<T>(String key, [T? fallback]) =>
      repository.get<T>(key, fallback);

  static bool has(String key) => repository.has(key);

  static T section<T extends ConfigSection>() => repository.section<T>();
}

/// Logging access.
abstract final class Log {
  static Logger get logger => Container.current.make<Logger>();

  /// A named channel (`Log::channel('daily')`).
  static Logger channel(String name) => logger.channelNamed(name);

  /// Adds context to the current request/job (or shares it globally).
  static void withContext(Map<String, Object?> context) =>
      logger.withContext(context);

  static void shareContext(Map<String, Object?> context) =>
      logger.shareContext(context);

  static void notice(String message, [Map<String, Object?>? context]) =>
      logger.notice(message, context);

  /// Captures records for assertions (`Log::spy()`); remove with
  /// `Log.logger.removeHandler(spy)`.
  static MemoryHandler spy() {
    final handler = MemoryHandler();
    logger.addHandler(handler);
    return handler;
  }

  static void debug(String message, [Map<String, Object?>? context]) =>
      logger.debug(message, context);

  static void info(String message, [Map<String, Object?>? context]) =>
      logger.info(message, context);

  static void warning(String message, [Map<String, Object?>? context]) =>
      logger.warning(message, context);

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
  static DatabaseManager get manager =>
      Container.current.make<DatabaseManager>();

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

  static Future<int> statement(
    String sql, [
    Object? bindings = const <Object?>[],
  ]) => manager.statement(sql, bindings);

  static Future<Object?> insertGetId(
    String sql, [
    Object? bindings = const <Object?>[],
  ]) => manager.insertGetId(sql, bindings);

  static Future<T> transaction<T>(
    Future<T> Function() body, {
    String? connection,
    int attempts = 1,
  }) =>
      manager.transaction<T>(body, connection: connection, attempts: attempts);

  static bool get inTransaction => manager.inTransaction;

  /// Calls [listener] after every query (`DB::listen`): SQL, bindings,
  /// duration and connection, for debugging and slow-query logging.
  static void listen(void Function(QueryExecuted event) listener) =>
      manager.listen(listener);

  /// Calls [handler] once the current request, job or command has spent
  /// more than [threshold] in queries (`DB::whenQueryingForLongerThan`).
  static void whenQueryingForLongerThan(
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
  static Future<SchemaBuilder> builder([String? connection]) async =>
      SchemaBuilder(await DB.manager.executor(connection));

  static Future<void> create(
    String table,
    void Function(Blueprint table) define,
  ) async => (await builder()).create(table, define);

  static Future<void> dropIfExists(String table) async =>
      (await builder()).dropIfExists(table);

  /// Columns of [table] (`Schema::getColumns`).
  static Future<List<ColumnInfo>> getColumns(String table) async =>
      (await builder()).getColumns(table);

  static Future<bool> hasTable(String table) async =>
      (await builder()).hasTable(table);

  static Future<void> table(
    String table,
    void Function(Blueprint table) define,
  ) async => (await builder()).table(table, define);

  static Future<bool> hasColumn(String table, String column) async =>
      (await builder()).hasColumn(table, column);

  static Future<void> drop(String table) async => (await builder()).drop(table);

  static Future<void> rename(String from, String to) async =>
      (await builder()).rename(from, to);
}

/// Reads an environment variable from the active application.
String? env(String key, [String? fallback]) =>
    Container.current.make<Env>().maybeString(key) ?? fallback;
