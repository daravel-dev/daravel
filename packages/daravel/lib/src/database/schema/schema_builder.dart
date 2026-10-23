import '../query_executor.dart';
import 'blueprint.dart';

/// Executes schema operations against a [QueryExecutor] (`Schema::create`,
/// `Schema::dropIfExists`, `Schema::hasTable`).
final class SchemaBuilder {
  SchemaBuilder(this._executor, {SchemaGrammar? grammar})
    : grammar = grammar ?? SchemaGrammar.forDialect(_executor.dialect);

  final QueryExecutor _executor;
  final SchemaGrammar grammar;

  /// Creates [table] using the columns defined by [define].
  Future<void> create(
    String table,
    void Function(Blueprint table) define,
  ) async {
    final blueprint = Blueprint(table);
    define(blueprint);
    if (blueprint.columns.isEmpty) {
      throw ArgumentError('Table [$table] must define at least one column.');
    }
    for (final statement in grammar.compileCreate(blueprint)) {
      await _executor.execute(statement);
    }
  }

  Future<void> drop(String table) =>
      _executor.execute(grammar.compileDrop(table));

  Future<void> dropIfExists(String table) =>
      _executor.execute(grammar.compileDropIfExists(table));

  Future<bool> hasTable(String table) async {
    final rows = await _executor.select(grammar.compileTableExists(), <Object?>[
      table,
    ]);
    return rows.isNotEmpty;
  }
}
