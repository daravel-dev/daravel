import '../query_executor.dart';
import 'blueprint.dart';
import 'sqlite_schema.dart';

/// Executes schema operations against a [QueryExecutor] (`Schema::create`,
/// `Schema::table`, `Schema::dropIfExists`, `Schema::hasTable`...).
final class SchemaBuilder {
  SchemaBuilder(this._executor, {SchemaGrammar? grammar})
    : grammar = grammar ?? SchemaGrammar.forDialect(_executor.dialect);

  final QueryExecutor _executor;
  final SchemaGrammar grammar;
  SqliteVersion? _sqliteVersion;

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

  /// Creates [table] unless it exists.
  Future<void> createIfNotExists(
    String table,
    void Function(Blueprint table) define,
  ) async {
    if (!await hasTable(table)) {
      await create(table, define);
    }
  }

  /// Alters [table] with the commands recorded by [define]. On SQLite,
  /// changes that `ALTER TABLE` cannot express rebuild the table.
  Future<void> table(
    String table,
    void Function(Blueprint table) define,
  ) async {
    final blueprint = Blueprint(table, alter: true);
    define(blueprint);
    final g = grammar;
    if (g is SqliteSchemaGrammar) {
      final version = await _sqlite();
      if (g.requiresRebuild(blueprint, version)) {
        await SqliteTableRebuilder(_executor, grammar: g).rebuild(blueprint);
        return;
      }
    }
    for (final statement in grammar.compileAlter(blueprint)) {
      await _executor.execute(statement);
    }
  }

  Future<void> drop(String table) =>
      _executor.execute(grammar.compileDrop(table));

  Future<void> dropIfExists(String table) =>
      _executor.execute(grammar.compileDropIfExists(table));

  Future<void> rename(String from, String to) =>
      _executor.execute(grammar.compileRename(from, to));

  Future<bool> hasTable(String table) async {
    final rows = await _executor.select(grammar.compileTableExists(), <Object?>[
      table,
    ]);
    return rows.isNotEmpty;
  }

  Future<bool> hasColumn(String table, String column) async =>
      (await getColumns(table)).any((c) => c.name == column);

  Future<bool> hasColumns(String table, List<String> columns) async {
    final existing = (await getColumns(table)).map((c) => c.name).toSet();
    return columns.every(existing.contains);
  }

  /// Column metadata for [table] (empty when the table does not exist).
  Future<List<ColumnInfo>> getColumns(String table) async {
    final g = grammar;
    final rows = g is SqliteSchemaGrammar
        ? await _executor.select('PRAGMA table_info(${g.wrap(table)})')
        : await _executor.select(g.compileColumns(), <Object?>[table]);
    if (g is SqliteSchemaGrammar && rows.isNotEmpty) {
      final sql = await _executor.select(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        <Object?>[table],
      );
      final auto =
          sql.isNotEmpty &&
          '${sql.first['sql']}'.toUpperCase().contains('AUTOINCREMENT');
      return [
        for (final row in rows)
          g.columnInfo({...row, 'autoincrement': auto && row['pk'] != 0}),
      ];
    }
    return [for (final row in rows) g.columnInfo(row)];
  }

  /// Names of the user tables.
  Future<List<String>> getTables() async {
    final rows = await _executor.select(grammar.compileListTables());
    return [for (final row in rows) row['name'] as String];
  }

  /// Drops every user table (used by `migrate:fresh`).
  Future<void> dropAllTables() async {
    final tables = await getTables();
    if (grammar is SqliteSchemaGrammar) {
      await _executor.execute('PRAGMA foreign_keys = OFF');
    }
    for (final table in tables) {
      await dropIfExists(table);
    }
    if (grammar is SqliteSchemaGrammar) {
      await _executor.execute('PRAGMA foreign_keys = ON');
    }
  }

  Future<SqliteVersion> _sqlite() async {
    final cached = _sqliteVersion;
    if (cached != null) {
      return cached;
    }
    final rows = await _executor.select('SELECT sqlite_version() AS v');
    return _sqliteVersion = SqliteVersion.parse('${rows.first['v']}');
  }
}
