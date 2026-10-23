import '../query_executor.dart';

/// Column types supported by the Tier 0 schema builder.
enum ColumnType {
  increments,
  string,
  text,
  integer,
  bigInteger,
  boolean,
  doublePrecision,
  timestamp,
}

/// A column being defined inside a [Blueprint].
final class ColumnDefinition {
  ColumnDefinition(this.name, this.type, {this.length});

  final String name;
  final ColumnType type;
  final int? length;

  bool _nullable = false;
  bool _unique = false;
  bool _hasDefault = false;
  Object? _defaultValue;

  bool get isNullable => _nullable;
  bool get isUnique => _unique;
  bool get hasDefault => _hasDefault;
  Object? get defaultValue => _defaultValue;
  bool get isAutoIncrement => type == ColumnType.increments;

  ColumnDefinition nullable([bool value = true]) {
    _nullable = value;
    return this;
  }

  ColumnDefinition unique() {
    _unique = true;
    return this;
  }

  ColumnDefinition defaultTo(Object? value) {
    _hasDefault = true;
    _defaultValue = value;
    return this;
  }
}

/// A table-level index.
final class IndexDefinition {
  const IndexDefinition(this.columns, {required this.unique, this.name});

  final List<String> columns;
  final bool unique;
  final String? name;
}

/// Collects column and index definitions for `Schema.create`.
final class Blueprint {
  Blueprint(this.table);

  final String table;
  final List<ColumnDefinition> columns = <ColumnDefinition>[];
  final List<IndexDefinition> indexes = <IndexDefinition>[];

  ColumnDefinition _add(ColumnDefinition column) {
    columns.add(column);
    return column;
  }

  /// Auto-incrementing primary key.
  ColumnDefinition id([String name = 'id']) =>
      _add(ColumnDefinition(name, ColumnType.increments));

  ColumnDefinition string(String name, {int length = 255}) =>
      _add(ColumnDefinition(name, ColumnType.string, length: length));

  ColumnDefinition text(String name) =>
      _add(ColumnDefinition(name, ColumnType.text));

  ColumnDefinition integer(String name) =>
      _add(ColumnDefinition(name, ColumnType.integer));

  ColumnDefinition bigInteger(String name) =>
      _add(ColumnDefinition(name, ColumnType.bigInteger));

  ColumnDefinition boolean(String name) =>
      _add(ColumnDefinition(name, ColumnType.boolean));

  ColumnDefinition doublePrecision(String name) =>
      _add(ColumnDefinition(name, ColumnType.doublePrecision));

  ColumnDefinition timestamp(String name) =>
      _add(ColumnDefinition(name, ColumnType.timestamp));

  /// Nullable `created_at` / `updated_at` columns.
  void timestamps() {
    timestamp('created_at').nullable();
    timestamp('updated_at').nullable();
  }

  void index(List<String> columns, {String? name}) =>
      indexes.add(IndexDefinition(columns, unique: false, name: name));

  void unique(List<String> columns, {String? name}) =>
      indexes.add(IndexDefinition(columns, unique: true, name: name));
}

/// Compiles blueprints into DDL for one dialect.
abstract class SchemaGrammar {
  const SchemaGrammar();

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Quotes an identifier after validating its characters (never trusts
  /// input: an invalid identifier throws instead of being interpolated).
  String wrap(String identifier) {
    if (!_identifier.hasMatch(identifier)) {
      throw ArgumentError.value(
        identifier,
        'identifier',
        'Invalid SQL identifier',
      );
    }
    return '"$identifier"';
  }

  List<String> compileCreate(Blueprint blueprint);

  String compileDropIfExists(String table) =>
      'DROP TABLE IF EXISTS ${wrap(table)}';

  String compileDrop(String table) => 'DROP TABLE ${wrap(table)}';

  /// Query returning one row when [table] exists (`?` binding = table name).
  String compileTableExists();

  String literal(Object? value) => switch (value) {
    null => 'NULL',
    bool() => value ? '1' : '0',
    num() => '$value',
    _ => "'${'$value'.replaceAll("'", "''")}'",
  };

  /// Picks the grammar for [dialect].
  static SchemaGrammar forDialect(SqlDialect dialect) => switch (dialect) {
    SqlDialect.sqlite => const SqliteSchemaGrammar(),
    SqlDialect.postgres || SqlDialect.mysql => throw UnsupportedError(
      'Schema grammar for $dialect arrives in slice S5.',
    ),
  };
}

/// SQLite DDL grammar.
final class SqliteSchemaGrammar extends SchemaGrammar {
  const SqliteSchemaGrammar();

  @override
  List<String> compileCreate(Blueprint blueprint) {
    final columns = blueprint.columns.map(_compileColumn).join(', ');
    final statements = <String>[
      'CREATE TABLE ${wrap(blueprint.table)} ($columns)',
    ];
    for (final index in blueprint.indexes) {
      final name =
          index.name ??
          '${blueprint.table}_${index.columns.join('_')}_${index.unique ? 'unique' : 'index'}';
      statements.add(
        'CREATE ${index.unique ? 'UNIQUE ' : ''}INDEX ${wrap(name)} ON '
        '${wrap(blueprint.table)} (${index.columns.map(wrap).join(', ')})',
      );
    }
    return statements;
  }

  @override
  String compileTableExists() =>
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?";

  String _compileColumn(ColumnDefinition column) {
    final buffer = StringBuffer()
      ..write(wrap(column.name))
      ..write(' ')
      ..write(_type(column));
    if (column.isAutoIncrement) {
      buffer.write(' PRIMARY KEY AUTOINCREMENT NOT NULL');
    } else {
      buffer.write(column.isNullable ? ' NULL' : ' NOT NULL');
    }
    if (column.hasDefault) {
      buffer
        ..write(' DEFAULT ')
        ..write(literal(column.defaultValue));
    }
    if (column.isUnique) {
      buffer.write(' UNIQUE');
    }
    return buffer.toString();
  }

  String _type(ColumnDefinition column) => switch (column.type) {
    ColumnType.increments => 'INTEGER',
    ColumnType.string => 'VARCHAR(${column.length ?? 255})',
    ColumnType.text => 'TEXT',
    ColumnType.integer => 'INTEGER',
    ColumnType.bigInteger => 'INTEGER',
    ColumnType.boolean => 'TINYINT(1)',
    ColumnType.doublePrecision => 'DOUBLE',
    ColumnType.timestamp => 'DATETIME',
  };
}
