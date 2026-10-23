import '../query_executor.dart';
import 'blueprint.dart';

/// PostgreSQL DDL grammar.
final class PostgresSchemaGrammar extends SchemaGrammar {
  const PostgresSchemaGrammar();

  @override
  SqlDialect get dialect => SqlDialect.postgres;

  @override
  String get autoIncrementClause => ' PRIMARY KEY';

  @override
  String typeFor(ColumnDefinition column) => switch (column.type) {
    ColumnType.increments => 'BIGSERIAL',
    ColumnType.string => 'VARCHAR(${column.length ?? 255})',
    ColumnType.char => 'CHAR(${column.length ?? 255})',
    ColumnType.text => 'TEXT',
    ColumnType.integer => 'INTEGER',
    ColumnType.tinyInteger || ColumnType.smallInteger => 'SMALLINT',
    ColumnType.bigInteger => 'BIGINT',
    ColumnType.decimal =>
      'DECIMAL(${column.precision ?? 8}, ${column.scale ?? 2})',
    ColumnType.float => 'REAL',
    ColumnType.doublePrecision => 'DOUBLE PRECISION',
    ColumnType.boolean => 'BOOLEAN',
    ColumnType.date => 'DATE',
    ColumnType.dateTime ||
    ColumnType.timestamp => 'TIMESTAMP(0) WITHOUT TIME ZONE',
    ColumnType.time => 'TIME(0) WITHOUT TIME ZONE',
    ColumnType.json => 'JSONB',
    ColumnType.uuid => 'UUID',
    ColumnType.binary => 'BYTEA',
    ColumnType.enumeration => 'VARCHAR(255)',
  };

  @override
  String literal(Object? value) => switch (value) {
    bool() => value ? 'TRUE' : 'FALSE',
    _ => super.literal(value),
  };

  @override
  String compileTableExists() =>
      r'SELECT tablename AS name FROM pg_tables WHERE schemaname = current_schema() AND tablename = $1';

  @override
  String compileListTables() =>
      "SELECT tablename AS name FROM pg_tables WHERE schemaname = current_schema() AND tablename NOT LIKE 'pg_%'";

  @override
  String compileColumns() =>
      'SELECT column_name AS name, data_type AS type, is_nullable AS nullable, column_default AS dflt '
      r'FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position';

  @override
  ColumnInfo columnInfo(Map<String, Object?> row) {
    final dflt = row['dflt'] as String?;
    return ColumnInfo(
      name: row['name'] as String,
      type: row['type'] as String,
      nullable: row['nullable'] == 'YES',
      defaultValue: dflt,
      autoIncrement: dflt != null && dflt.startsWith('nextval('),
    );
  }

  @override
  String compileDrop(String table) => 'DROP TABLE ${wrap(table)} CASCADE';

  @override
  String compileDropIfExists(String table) =>
      'DROP TABLE IF EXISTS ${wrap(table)} CASCADE';

  @override
  List<String> compileChange(String table, ColumnDefinition column) {
    final t = wrap(table);
    final c = wrap(column.name);
    return <String>[
      'ALTER TABLE $t ALTER COLUMN $c TYPE ${typeFor(column)}',
      'ALTER TABLE $t ALTER COLUMN $c ${column.isNullable ? 'DROP NOT NULL' : 'SET NOT NULL'}',
      if (column.hasDefault)
        'ALTER TABLE $t ALTER COLUMN $c SET${defaultClause(column)}'
      else
        'ALTER TABLE $t ALTER COLUMN $c DROP DEFAULT',
    ];
  }
}

/// MySQL/MariaDB DDL grammar.
final class MySqlSchemaGrammar extends SchemaGrammar {
  const MySqlSchemaGrammar();

  @override
  SqlDialect get dialect => SqlDialect.mysql;

  @override
  String get quoteOpen => '`';

  @override
  String get quoteClose => '`';

  @override
  String get autoIncrementClause =>
      ' UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY';

  @override
  bool get supportsUnsigned => true;

  @override
  bool get enumAsCheck => false;

  @override
  String get createSuffix =>
      ' DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci';

  @override
  String typeFor(ColumnDefinition column) => switch (column.type) {
    ColumnType.increments => 'BIGINT',
    ColumnType.string => 'VARCHAR(${column.length ?? 255})',
    ColumnType.char => 'CHAR(${column.length ?? 255})',
    ColumnType.text => 'TEXT',
    ColumnType.integer => 'INT',
    ColumnType.tinyInteger => 'TINYINT',
    ColumnType.smallInteger => 'SMALLINT',
    ColumnType.bigInteger => 'BIGINT',
    ColumnType.decimal =>
      'DECIMAL(${column.precision ?? 8}, ${column.scale ?? 2})',
    ColumnType.float => 'FLOAT',
    ColumnType.doublePrecision => 'DOUBLE',
    ColumnType.boolean => 'TINYINT(1)',
    ColumnType.date => 'DATE',
    ColumnType.dateTime => 'DATETIME',
    ColumnType.time => 'TIME',
    ColumnType.timestamp => 'TIMESTAMP',
    ColumnType.json => 'JSON',
    ColumnType.uuid => 'CHAR(36)',
    ColumnType.binary => 'BLOB',
    ColumnType.enumeration => 'ENUM(${column.allowed.map(literal).join(', ')})',
  };

  @override
  String compileTableExists() =>
      'SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?';

  @override
  String compileListTables() =>
      'SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE()';

  @override
  String compileColumns() =>
      'SELECT column_name AS name, column_type AS type, is_nullable AS nullable, column_default AS dflt, extra '
      'FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position';

  @override
  ColumnInfo columnInfo(Map<String, Object?> row) => ColumnInfo(
    name: row['name'] as String,
    type: row['type'] as String,
    nullable: row['nullable'] == 'YES',
    defaultValue: row['dflt'] as String?,
    autoIncrement: '${row['extra']}'.contains('auto_increment'),
  );

  @override
  String compileDropIndex(String table, String name) =>
      'DROP INDEX ${wrap(name)} ON ${wrap(table)}';

  @override
  String compileDropForeign(String table, String name) =>
      'ALTER TABLE ${wrap(table)} DROP FOREIGN KEY ${wrap(name)}';

  @override
  String compileRename(String from, String to) =>
      'RENAME TABLE ${wrap(from)} TO ${wrap(to)}';

  @override
  List<String> compileChange(String table, ColumnDefinition column) => <String>[
    'ALTER TABLE ${wrap(table)} MODIFY ${compileColumn(column)}',
  ];
}
