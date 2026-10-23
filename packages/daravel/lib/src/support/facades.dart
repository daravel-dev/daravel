import '../database/database_manager.dart';
import '../database/query/query_ast.dart';
import '../database/query/query_builder.dart';
import '../database/query_executor.dart';
import '../database/schema/blueprint.dart';
import '../database/schema/schema_builder.dart';
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
}

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

  static Future<bool> hasTable(String table) async =>
      (await builder()).hasTable(table);
}

/// Reads an environment variable from the active application.
String? env(String key, [String? fallback]) =>
    Container.current.make<Env>().maybeString(key) ?? fallback;
