import 'blueprint.dart';

/// PostgreSQL DDL grammar.
final class PostgresSchemaGrammar extends SchemaGrammar {
  const PostgresSchemaGrammar();

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
      'SELECT tablename FROM pg_tables WHERE schemaname = current_schema() '
      r'AND tablename = $1';

  @override
  String literal(Object? value) => switch (value) {
    bool() => value ? 'TRUE' : 'FALSE',
    _ => super.literal(value),
  };

  String _compileColumn(ColumnDefinition column) {
    final buffer = StringBuffer()
      ..write(wrap(column.name))
      ..write(' ')
      ..write(_type(column));
    if (column.isAutoIncrement) {
      buffer.write(' PRIMARY KEY');
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
    ColumnType.increments => 'BIGSERIAL',
    ColumnType.string => 'VARCHAR(${column.length ?? 255})',
    ColumnType.text => 'TEXT',
    ColumnType.integer => 'INTEGER',
    ColumnType.bigInteger => 'BIGINT',
    ColumnType.boolean => 'BOOLEAN',
    ColumnType.doublePrecision => 'DOUBLE PRECISION',
    ColumnType.timestamp => 'TIMESTAMP(0) WITHOUT TIME ZONE',
  };
}

/// MySQL/MariaDB DDL grammar.
final class MySqlSchemaGrammar extends SchemaGrammar {
  const MySqlSchemaGrammar();

  @override
  String wrap(String identifier) => super.wrap(identifier).replaceAll('"', '`');

  @override
  List<String> compileCreate(Blueprint blueprint) {
    final columns = blueprint.columns.map(_compileColumn).toList();
    for (final index in blueprint.indexes) {
      final name =
          index.name ??
          '${blueprint.table}_${index.columns.join('_')}_${index.unique ? 'unique' : 'index'}';
      columns.add(
        '${index.unique ? 'UNIQUE ' : ''}INDEX ${wrap(name)} '
        '(${index.columns.map(wrap).join(', ')})',
      );
    }
    return <String>[
      'CREATE TABLE ${wrap(blueprint.table)} (${columns.join(', ')}) '
          'DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci',
    ];
  }

  @override
  String compileTableExists() =>
      'SELECT table_name FROM information_schema.tables '
      'WHERE table_schema = DATABASE() AND table_name = ?';

  String _compileColumn(ColumnDefinition column) {
    final buffer = StringBuffer()
      ..write(wrap(column.name))
      ..write(' ')
      ..write(_type(column));
    if (column.isAutoIncrement) {
      buffer.write(' NOT NULL AUTO_INCREMENT PRIMARY KEY');
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
    ColumnType.increments => 'BIGINT UNSIGNED',
    ColumnType.string => 'VARCHAR(${column.length ?? 255})',
    ColumnType.text => 'TEXT',
    ColumnType.integer => 'INT',
    ColumnType.bigInteger => 'BIGINT',
    ColumnType.boolean => 'TINYINT(1)',
    ColumnType.doublePrecision => 'DOUBLE',
    ColumnType.timestamp => 'TIMESTAMP NULL',
  };
}
