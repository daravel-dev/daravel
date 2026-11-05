import '../query_executor.dart';
import 'blueprint.dart';
import 'sqlite_schema.dart';

/// Executes schema operations against a [QueryExecutor] (`Schema::create`,
/// `Schema::table`, `Schema::dropIfExists`, `Schema::hasTable`...).
final class SchemaBuilder {
  /// A schema builder on a connection, with the grammar of its dialect.
  SchemaBuilder(this._executor, {SchemaGrammar? grammar})
    : grammar = grammar ?? SchemaGrammar.forDialect(_executor.dialect);

  final QueryExecutor _executor;

  /// The grammar writing the DDL.
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

  /// Drops [table]; fails when it does not exist.
  Future<void> drop(String table) =>
      _executor.execute(grammar.compileDrop(table));

  /// Creates the `pgvector` extension (`Schema::ensureVectorExtensionExists`).
  Future<void> ensureVectorExtensionExists({String? schema}) =>
      ensureExtensionExists('vector', schema: schema);

  /// Creates a PostgreSQL extension unless it exists.
  Future<void> ensureExtensionExists(String name, {String? schema}) {
    if (grammar.dialect != .postgres) {
      throw UnsupportedError('Extensions are only supported by PostgreSQL.');
    }
    final into = schema == null ? '' : ' SCHEMA ${grammar.wrap(schema)}';
    return _executor.execute(
      'CREATE EXTENSION IF NOT EXISTS ${grammar.wrap(name)}$into',
    );
  }

  /// Drops [table] when it exists.
  Future<void> dropIfExists(String table) =>
      _executor.execute(grammar.compileDropIfExists(table));

  /// Renames the table [from] to [to].
  Future<void> rename(String from, String to) =>
      _executor.execute(grammar.compileRename(from, to));

  /// Whether the table [table] exists.
  Future<bool> hasTable(String table) async {
    final rows = await _executor.select(
      grammar.compileTableExists(),
      grammar.tableBindings(table),
    );
    return rows.isNotEmpty;
  }

  /// Whether the view [view] exists (`schema.view` on PostgreSQL, like
  /// [hasTable]).
  Future<bool> hasView(String view) async {
    final rows = await _executor.select(
      grammar.compileViewExists(),
      grammar.tableBindings(view),
    );
    return rows.isNotEmpty;
  }

  /// Whether [table] has the column [column].
  Future<bool> hasColumn(String table, String column) async =>
      (await getColumns(table)).any((c) => c.name == column);

  /// Whether [table] has every one of [columns].
  Future<bool> hasColumns(String table, List<String> columns) async {
    final existing = (await getColumns(table)).map((c) => c.name).toSet();
    return columns.every(existing.contains);
  }

  /// Column metadata for [table] (empty when the table does not exist).
  Future<List<ColumnInfo>> getColumns(String table) async {
    final g = grammar;
    final rows = g is SqliteSchemaGrammar
        ? await _executor.select('PRAGMA table_info(${g.wrap(table)})')
        : await _executor.select(g.compileColumns(), g.tableBindings(table));
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

  /// Drops every user table (used by `migrate:fresh`), whatever foreign
  /// keys join them.
  ///
  /// SQLite turns foreign keys off around the drops and PostgreSQL drops
  /// with `CASCADE`. MySQL and MariaDB first drop every foreign key of the
  /// database, then the tables in one `DROP TABLE`. Laravel sets
  /// `FOREIGN_KEY_CHECKS = 0` instead, which holds for one session only: on
  /// a pool the drops can run on another connection, and the connection
  /// that took the setting would go back to the pool with its checks off.
  Future<void> dropAllTables() async {
    final tables = await getTables();
    if (grammar.dialect.isMySqlFamily) {
      final keys = await _executor.select(
        'SELECT table_name AS tbl, constraint_name AS name '
        'FROM information_schema.table_constraints '
        "WHERE table_schema = DATABASE() AND constraint_type = 'FOREIGN KEY'",
      );
      for (final key in keys) {
        await _executor.execute(
          grammar.compileDropForeign('${key['tbl']}', '${key['name']}'),
        );
      }
      if (tables.isNotEmpty) {
        await _executor.execute(
          'DROP TABLE IF EXISTS ${tables.map(grammar.wrap).join(', ')}',
        );
      }
      return;
    }
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
