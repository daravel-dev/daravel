import '../query_executor.dart';
import 'schema_grammars.dart';
import 'sqlite_schema.dart';

/// Column types supported by the schema builder.
enum ColumnType {
  /// An auto-incrementing integer primary key ([Blueprint.id], [Blueprint.increments]).
  increments,

  /// `VARCHAR(length)` ([Blueprint.string]).
  string,

  /// Fixed-length `CHAR(length)` ([Blueprint.char]).
  char,

  /// `TEXT` ([Blueprint.text]).
  text,

  /// `MEDIUMTEXT` on MySQL, `TEXT` elsewhere ([Blueprint.mediumText]).
  mediumText,

  /// `LONGTEXT` on MySQL, `TEXT` elsewhere ([Blueprint.longText]).
  longText,

  /// A 32-bit integer ([Blueprint.integer]).
  integer,

  /// An 8-bit integer ([Blueprint.tinyInteger]).
  tinyInteger,

  /// A 16-bit integer ([Blueprint.smallInteger]).
  smallInteger,

  /// A 64-bit integer ([Blueprint.bigInteger]).
  bigInteger,

  /// A fixed-point number with a precision and scale ([Blueprint.decimal]).
  decimal,

  /// A single-precision floating point number ([Blueprint.float]).
  float,

  /// A double-precision floating point number ([Blueprint.doublePrecision]).
  doublePrecision,

  /// A boolean; `TINYINT(1)` on MySQL, an integer on SQLite ([Blueprint.boolean]).
  boolean,

  /// A date without a time ([Blueprint.date]).
  date,

  /// A date and time ([Blueprint.dateTime]).
  dateTime,

  /// A time of day ([Blueprint.time]).
  time,

  /// A timestamp ([Blueprint.timestamp], [Blueprint.timestamps]).
  timestamp,

  /// JSON; `JSONB` on PostgreSQL, text on SQLite ([Blueprint.json]).
  json,

  /// A UUID; `UUID` on PostgreSQL, `CHAR(36)` elsewhere ([Blueprint.uuid]).
  uuid,

  /// Binary data: `BLOB` or `BYTEA` ([Blueprint.binary]).
  binary,

  /// One of a fixed list of strings ([Blueprint.enumeration]).
  enumeration,

  /// A vector of numbers for similarity search ([Blueprint.vector]).
  vector,

  /// A PostgreSQL full text `tsvector` ([Blueprint.tsvector]).
  tsvector,
}

/// A column being defined (or changed) inside a [Blueprint].
final class ColumnDefinition {
  /// A column named [name] of [type]; [Blueprint]'s column methods create
  /// it, so application code rarely calls this.
  ColumnDefinition(
    this.name,
    this.type, {
    this.length,
    this.precision,
    this.scale,
    this.allowed = const <String>[],
  });

  /// The column name.
  final String name;

  /// The column type.
  final ColumnType type;

  /// The length of a string or char column, or the dimensions of a vector.
  final int? length;

  /// The total number of digits of a decimal column.
  final int? precision;

  /// The digits after the decimal point of a decimal column.
  final int? scale;

  /// Allowed values for [ColumnType.enumeration].
  final List<String> allowed;

  bool _nullable = false;
  bool _unique = false;
  bool _primary = false;
  bool _index = false;
  bool _unsigned = false;
  bool _useCurrent = false;
  bool _hasDefault = false;
  bool _change = false;
  Object? _defaultValue;
  String? _defaultRaw;
  String? _comment;

  /// Whether the column accepts `NULL` ([nullable]).
  bool get isNullable => _nullable;

  /// Whether the column has a unique index ([unique]).
  bool get isUnique => _unique;

  /// Whether the column is the primary key ([primary]).
  bool get isPrimary => _primary;

  /// Whether the column has a plain index ([index]).
  bool get hasIndex => _index;

  /// Whether the column is `UNSIGNED` on MySQL ([unsigned]).
  bool get isUnsigned => _unsigned;

  /// Whether the column defaults to `CURRENT_TIMESTAMP` ([useCurrent]).
  bool get usesCurrent => _useCurrent;

  /// Whether the column has any default: a value, raw SQL or the current time.
  bool get hasDefault => _hasDefault || _defaultRaw != null || _useCurrent;

  /// The default given to [defaultTo].
  Object? get defaultValue => _defaultValue;

  /// The raw SQL default given to [defaultRaw].
  String? get rawDefault => _defaultRaw;

  /// The comment given to [comment].
  String? get commentText => _comment;

  /// Whether this modifies an existing column ([change]).
  bool get isChange => _change;

  /// Whether the column is an auto-incrementing primary key.
  bool get isAutoIncrement => type == .increments;

  /// Allows `NULL` in the column (`->nullable()`); `nullable(false)` makes it
  /// `NOT NULL` again when changing a column.
  ColumnDefinition nullable([bool value = true]) {
    _nullable = value;
    return this;
  }

  /// Adds a unique index on the column (`->unique()`).
  ColumnDefinition unique() {
    _unique = true;
    return this;
  }

  /// Makes the column the primary key (`->primary()`).
  ColumnDefinition primary() {
    _primary = true;
    return this;
  }

  /// Adds an index on the column (`->index()`).
  ColumnDefinition index() {
    _index = true;
    return this;
  }

  /// Makes the column `UNSIGNED` on MySQL; other databases ignore it.
  ColumnDefinition unsigned() {
    _unsigned = true;
    return this;
  }

  /// The column's default value (`->default($value)`), written as a SQL
  /// literal.
  ColumnDefinition defaultTo(Object? value) {
    _hasDefault = true;
    _defaultValue = value;
    return this;
  }

  /// Raw SQL default (`defaultRaw('CURRENT_TIMESTAMP')`).
  ColumnDefinition defaultRaw(String expression) {
    _defaultRaw = expression;
    return this;
  }

  /// `DEFAULT CURRENT_TIMESTAMP` for timestamp columns.
  ColumnDefinition useCurrent() {
    _useCurrent = true;
    return this;
  }

  /// A comment on the column (`->comment('...')`).
  ColumnDefinition comment(String text) {
    _comment = text;
    return this;
  }

  /// Marks the column as a modification of an existing column
  /// (`Schema.table` only).
  ColumnDefinition change() {
    _change = true;
    return this;
  }
}

/// A `foreignId()` column that can be `constrained()`.
final class ForeignIdDefinition extends ColumnDefinition {
  /// A foreign id column of [blueprint]; created by [Blueprint.foreignId].
  ForeignIdDefinition(super.name, super.type, this._blueprint);

  final Blueprint _blueprint;

  /// Adds a foreign key to [table] (guessed from the column name:
  /// `user_id` → `users`) referencing [column].
  ForeignKeyDefinition constrained([String? table, String column = 'id']) {
    final target = table ?? guessTable(name);
    return _blueprint.foreign([name]).references(column).on(target);
  }

  /// `user_id` → `users`, `category_id` → `categories`.
  static String guessTable(String column) {
    final base = column.endsWith('_id')
        ? column.substring(0, column.length - 3)
        : column;
    if (base.endsWith('y') && !base.endsWith('ey')) {
      return '${base.substring(0, base.length - 1)}ies';
    }
    if (base.endsWith('s') ||
        base.endsWith('x') ||
        base.endsWith('ch') ||
        base.endsWith('sh')) {
      return '${base}es';
    }
    return '${base}s';
  }

  @override
  ForeignIdDefinition nullable([bool value = true]) {
    super.nullable(value);
    return this;
  }
}

/// A foreign key constraint.
final class ForeignKeyDefinition {
  /// A foreign key on [columns]; created by [Blueprint.foreign] and
  /// [ForeignIdDefinition.constrained].
  ForeignKeyDefinition(this.columns, {this._name});

  /// The local columns of the key.
  final List<String> columns;
  final String? _name;

  /// The columns it references in [referencedTable] (`id` by default).
  List<String> referencedColumns = const <String>['id'];

  /// The table it references ([on]).
  String? referencedTable;

  /// The `ON DELETE` action ([onDelete]), upper case.
  String? onDeleteAction;

  /// The `ON UPDATE` action ([onUpdate]), upper case.
  String? onUpdateAction;

  /// Constraint name (`<table>_<columns>_foreign` when unset).
  String nameFor(String table) =>
      _name ?? '${table}_${columns.join('_')}_foreign';

  /// The referenced column, or a list of columns (`->references('id')`).
  ForeignKeyDefinition references(Object column) {
    referencedColumns = column is List<String> ? column : <String>['$column'];
    return this;
  }

  /// The referenced table (`->on('users')`).
  ForeignKeyDefinition on(String table) {
    referencedTable = table;
    return this;
  }

  /// The action when the referenced row is deleted: `cascade`, `restrict`,
  /// `set null` or `no action`.
  ForeignKeyDefinition onDelete(String action) {
    onDeleteAction = action.toUpperCase();
    return this;
  }

  /// The action when the referenced key changes.
  ForeignKeyDefinition onUpdate(String action) {
    onUpdateAction = action.toUpperCase();
    return this;
  }

  /// Deletes the rows when the referenced row is deleted.
  ForeignKeyDefinition cascadeOnDelete() => onDelete('cascade');

  /// Refuses to delete a referenced row while rows point at it.
  ForeignKeyDefinition restrictOnDelete() => onDelete('restrict');

  /// Sets the column to `NULL` when the referenced row is deleted.
  ForeignKeyDefinition nullOnDelete() => onDelete('set null');

  /// Updates the column when the referenced key changes.
  ForeignKeyDefinition cascadeOnUpdate() => onUpdate('cascade');
}

/// A table-level index.
final class IndexDefinition {
  /// An index on [columns]; [unique] makes it a unique index.
  const IndexDefinition(
    this.columns, {
    required this.unique,
    this.name,
    this.vector = false,
  });

  /// The indexed columns, in order.
  final List<String> columns;

  /// Whether the index is unique.
  final bool unique;

  /// The index name; Laravel's `<table>_<columns>_<kind>` when null.
  final String? name;

  /// An approximate index for distance queries ([Blueprint.vectorIndex]).
  final bool vector;

  /// The index name in [table]: [name], or `<table>_<columns>_index`,
  /// `_unique` or `_vectorindex` as Laravel names it.
  String nameFor(String table) =>
      name ??
      '${table}_${columns.join('_')}_'
          '${vector
              ? 'vectorindex'
              : unique
              ? 'unique'
              : 'index'}';
}

/// Collects column, index and foreign key definitions for `Schema.create`
/// and the change commands for `Schema.table`.
final class Blueprint {
  /// A blueprint for [table]; [alter] when it changes an existing table.
  /// `Schema.create` and `Schema.table` create it for the callback.
  Blueprint(this.table, {this.alter = false});

  /// The table being created or changed.
  final String table;

  /// Whether this blueprint modifies an existing table.
  final bool alter;

  /// The columns added or changed, in order.
  final List<ColumnDefinition> columns = <ColumnDefinition>[];

  /// The table-level indexes ([index], [unique], [vectorIndex]).
  final List<IndexDefinition> indexes = <IndexDefinition>[];

  /// The foreign keys ([foreign], [ForeignIdDefinition.constrained]).
  final List<ForeignKeyDefinition> foreignKeys = <ForeignKeyDefinition>[];

  /// A primary key over several columns ([primary]), when creating.
  IndexDefinition? primaryKey;

  /// Columns to drop ([dropColumn]).
  final List<String> dropColumns = <String>[];

  /// Columns to rename, as (from, to) ([renameColumn]).
  final List<(String, String)> renameColumns = <(String, String)>[];

  /// Indexes to drop by name ([dropIndex], [dropUnique]).
  final List<String> dropIndexes = <String>[];

  /// Foreign keys to drop by name ([dropForeign]).
  final List<String> dropForeignKeys = <String>[];

  /// Columns being added (not changed).
  List<ColumnDefinition> get addedColumns =>
      columns.where((c) => !c.isChange).toList();

  /// Columns being changed.
  List<ColumnDefinition> get changedColumns =>
      columns.where((c) => c.isChange).toList();

  ColumnDefinition _add(ColumnDefinition column) {
    columns.add(column);
    return column;
  }

  /// Auto-incrementing primary key.
  ColumnDefinition id([String name = 'id']) =>
      _add(ColumnDefinition(name, ColumnType.increments));

  /// UUID primary key (client generated).
  ColumnDefinition uuid([String name = 'uuid']) =>
      _add(ColumnDefinition(name, ColumnType.uuid));

  /// ULID column (26 chars).
  ColumnDefinition ulid([String name = 'ulid']) =>
      _add(ColumnDefinition(name, ColumnType.char, length: 26));

  /// `BIGINT UNSIGNED` style foreign key column; chain `.constrained()`.
  ForeignIdDefinition foreignId(String name) {
    final column = ForeignIdDefinition(name, ColumnType.bigInteger, this)
      ..unsigned();
    columns.add(column);
    return column;
  }

  /// UUID foreign key column; chain `.constrained()`.
  ForeignIdDefinition foreignUuid(String name) {
    final column = ForeignIdDefinition(name, ColumnType.uuid, this);
    columns.add(column);
    return column;
  }

  /// Polymorphic columns `{name}_type` (string) and `{name}_id` (unsigned
  /// big integer) with a composite index, as Laravel's `morphs()` creates.
  void morphs(String name, {String? indexName}) =>
      _morphs(name, unsignedBigInteger, nullable: false, indexName: indexName);

  /// [morphs] with both columns nullable.
  void nullableMorphs(String name, {String? indexName}) =>
      _morphs(name, unsignedBigInteger, nullable: true, indexName: indexName);

  /// [morphs] with a UUID `{name}_id`.
  void uuidMorphs(String name, {String? indexName}) =>
      _morphs(name, uuid, nullable: false, indexName: indexName);

  /// [uuidMorphs] with both columns nullable.
  void nullableUuidMorphs(String name, {String? indexName}) =>
      _morphs(name, uuid, nullable: true, indexName: indexName);

  /// [morphs] with a ULID `{name}_id`.
  void ulidMorphs(String name, {String? indexName}) =>
      _morphs(name, ulid, nullable: false, indexName: indexName);

  /// [ulidMorphs] with both columns nullable.
  void nullableUlidMorphs(String name, {String? indexName}) =>
      _morphs(name, ulid, nullable: true, indexName: indexName);

  void _morphs(
    String name,
    ColumnDefinition Function(String name) id, {
    required bool nullable,
    String? indexName,
  }) {
    final type = string('${name}_type');
    final key = id('${name}_id');
    if (nullable) {
      type.nullable();
      key.nullable();
    }
    index(['${name}_type', '${name}_id'], name: indexName);
  }

  /// A `VARCHAR` column of up to [length] characters (`$table->string()`).
  ColumnDefinition string(String name, {int length = 255}) =>
      _add(ColumnDefinition(name, ColumnType.string, length: length));

  /// A fixed-length `CHAR` column of [length] characters.
  ColumnDefinition char(String name, {int length = 255}) =>
      _add(ColumnDefinition(name, ColumnType.char, length: length));

  /// A `TEXT` column.
  ColumnDefinition text(String name) =>
      _add(ColumnDefinition(name, ColumnType.text));

  /// `MEDIUMTEXT` on MySQL (16 MB), `TEXT` elsewhere.
  ColumnDefinition mediumText(String name) =>
      _add(ColumnDefinition(name, ColumnType.mediumText));

  /// `LONGTEXT` on MySQL (4 GB), `TEXT` elsewhere.
  ColumnDefinition longText(String name) =>
      _add(ColumnDefinition(name, ColumnType.longText));

  /// A 32-bit integer column.
  ColumnDefinition integer(String name) =>
      _add(ColumnDefinition(name, ColumnType.integer));

  /// An 8-bit integer column.
  ColumnDefinition tinyInteger(String name) =>
      _add(ColumnDefinition(name, ColumnType.tinyInteger));

  /// A 16-bit integer column.
  ColumnDefinition smallInteger(String name) =>
      _add(ColumnDefinition(name, ColumnType.smallInteger));

  /// A 64-bit integer column.
  ColumnDefinition bigInteger(String name) =>
      _add(ColumnDefinition(name, ColumnType.bigInteger));

  /// An unsigned 64-bit integer column (unsigned on MySQL only).
  ColumnDefinition unsignedBigInteger(String name) =>
      bigInteger(name).unsigned();

  /// An unsigned 32-bit integer column (unsigned on MySQL only).
  ColumnDefinition unsignedInteger(String name) => integer(name).unsigned();

  /// A fixed-point column of [precision] digits, [scale] of them after the
  /// point: `decimal('price', precision: 10, scale: 2)`.
  ColumnDefinition decimal(String name, {int precision = 8, int scale = 2}) =>
      _add(
        ColumnDefinition(
          name,
          ColumnType.decimal,
          precision: precision,
          scale: scale,
        ),
      );

  /// A single-precision floating point column.
  ColumnDefinition float(String name) =>
      _add(ColumnDefinition(name, ColumnType.float));

  /// A double-precision floating point column (`$table->double()`).
  ColumnDefinition doublePrecision(String name) =>
      _add(ColumnDefinition(name, ColumnType.doublePrecision));

  /// A boolean column.
  ColumnDefinition boolean(String name) =>
      _add(ColumnDefinition(name, ColumnType.boolean));

  /// A date column.
  ColumnDefinition date(String name) =>
      _add(ColumnDefinition(name, ColumnType.date));

  /// A date and time column.
  ColumnDefinition dateTime(String name) =>
      _add(ColumnDefinition(name, ColumnType.dateTime));

  /// A time of day column.
  ColumnDefinition time(String name) =>
      _add(ColumnDefinition(name, ColumnType.time));

  /// A timestamp column.
  ColumnDefinition timestamp(String name) =>
      _add(ColumnDefinition(name, ColumnType.timestamp));

  /// A JSON column: `JSONB` on PostgreSQL, `JSON` on MySQL, text on SQLite.
  ColumnDefinition json(String name) =>
      _add(ColumnDefinition(name, ColumnType.json));

  /// Laravel's `jsonb()`; the same as [json], which is already `JSONB` on
  /// PostgreSQL.
  ColumnDefinition jsonb(String name) => json(name);

  /// A `pgvector` column of [dimensions] numbers. SQLite stores it as text, so
  /// a migration still runs in tests, without distance queries.
  ColumnDefinition vector(String name, {int? dimensions}) =>
      _add(ColumnDefinition(name, ColumnType.vector, length: dimensions));

  /// A PostgreSQL `tsvector` column; text on SQLite.
  ColumnDefinition tsvector(String name) =>
      _add(ColumnDefinition(name, ColumnType.tsvector));

  /// A binary column: `BLOB` or `BYTEA`.
  ColumnDefinition binary(String name) =>
      _add(ColumnDefinition(name, ColumnType.binary));

  /// Enum column (emulated with a CHECK constraint where needed).
  ColumnDefinition enumeration(String name, List<String> allowed) =>
      _add(ColumnDefinition(name, ColumnType.enumeration, allowed: allowed));

  /// Nullable `created_at` / `updated_at` columns.
  void timestamps() {
    timestamp('created_at').nullable();
    timestamp('updated_at').nullable();
  }

  /// Nullable `deleted_at` column for soft deletes.
  ColumnDefinition softDeletes([String name = 'deleted_at']) =>
      timestamp(name).nullable();

  /// Nullable `remember_token` column.
  ColumnDefinition rememberToken() =>
      string('remember_token', length: 100).nullable();

  /// An HNSW index with cosine distance, as Laravel's `vectorIndex`. SQLite
  /// has none, and goes without.
  void vectorIndex(String column, {String? name}) => indexes.add(
    IndexDefinition([column], unique: false, name: name, vector: true),
  );

  /// An index on [columns], named `<table>_<columns>_index` unless [name] is
  /// given.
  void index(List<String> columns, {String? name}) =>
      indexes.add(IndexDefinition(columns, unique: false, name: name));

  /// A unique index on [columns], named `<table>_<columns>_unique` unless
  /// [name] is given.
  void unique(List<String> columns, {String? name}) =>
      indexes.add(IndexDefinition(columns, unique: true, name: name));

  /// A primary key over [columns] (`$table->primary([...])`), named as
  /// Laravel names it unless [name] is given: `<table>_<columns>_primary`.
  void primary(List<String> columns, {String? name}) =>
      primaryKey = IndexDefinition(
        columns,
        unique: true,
        name: name ?? '${table}_${columns.join('_')}_primary',
      );

  /// Starts a foreign key on [columns]; chain `.references().on()`.
  ForeignKeyDefinition foreign(List<String> columns, {String? name}) {
    final key = ForeignKeyDefinition(columns, name: name);
    foreignKeys.add(key);
    return key;
  }

  // --- change commands (Schema.table) ---------------------------------------

  /// Drops a column, or a list of columns (`Schema.table` only).
  void dropColumn(Object names) =>
      dropColumns.addAll(names is List<String> ? names : <String>['$names']);

  /// Renames the column [from] to [to] (`Schema.table` only).
  void renameColumn(String from, String to) => renameColumns.add((from, to));

  /// Drops the index named [name].
  void dropIndex(String name) => dropIndexes.add(name);

  /// Drops the unique index named [name].
  void dropUnique(String name) => dropIndexes.add(name);

  /// Drops a foreign key by constraint name or by its columns.
  void dropForeign(Object nameOrColumns) => dropForeignKeys.add(
    nameOrColumns is List<String>
        ? '${table}_${nameOrColumns.join('_')}_foreign'
        : '$nameOrColumns',
  );

  /// Drops the soft delete column ([softDeletes]).
  void dropSoftDeletes([String name = 'deleted_at']) => dropColumn(name);

  /// Drops `created_at` and `updated_at` ([timestamps]).
  void dropTimestamps() => dropColumn(const ['created_at', 'updated_at']);
}

/// Column metadata returned by `Schema.getColumns`.
final class ColumnInfo {
  /// Metadata of one column, as `Schema.getColumns` returns it.
  const ColumnInfo({
    required this.name,
    required this.type,
    required this.nullable,
    this.defaultValue,
    this.autoIncrement = false,
    this.primary = false,
  });

  /// The column name.
  final String name;

  /// The column type as the database reports it, such as `varchar(255)`.
  final String type;

  /// Whether the column accepts `NULL`.
  final bool nullable;

  /// The default as the database reports it, or null.
  final String? defaultValue;

  /// Whether the column auto-increments.
  final bool autoIncrement;

  /// Whether the column is (part of) the primary key.
  final bool primary;

  @override
  String toString() => 'ColumnInfo($name $type${nullable ? ' null' : ''})';
}

/// Compiles blueprints into DDL for one dialect.
abstract class SchemaGrammar {
  /// Grammars are stateless; [forDialect] picks one.
  const SchemaGrammar();

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// The database dialect this grammar writes for.
  SqlDialect get dialect;

  /// The character that opens a quoted identifier: `"`, or a backtick on
  /// MySQL.
  String get quoteOpen => '"';

  /// The character that closes a quoted identifier.
  String get quoteClose => '"';

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
    return '$quoteOpen$identifier$quoteClose';
  }

  /// Picks the grammar for [dialect].
  static SchemaGrammar forDialect(SqlDialect dialect) => switch (dialect) {
    .sqlite => const SqliteSchemaGrammar(),
    .postgres => const PostgresSchemaGrammar(),
    .mysql => const MySqlSchemaGrammar(),
    .mariadb => const MySqlSchemaGrammar(SqlDialect.mariadb),
  };

  // --- hooks -----------------------------------------------------------------

  /// SQL type for [column].
  String typeFor(ColumnDefinition column);

  /// Clause appended to an auto-increment column (after the type).
  String get autoIncrementClause;

  /// Whether `UNSIGNED` is supported.
  bool get supportsUnsigned => false;

  /// Whether inline `UNIQUE` on a column is used (else a unique index).
  bool get inlineUnique => false;

  /// Whether enum columns need a CHECK constraint.
  bool get enumAsCheck => true;

  /// The bindings of [compileTableExists], [compileViewExists] and
  /// [compileColumns] for [table].
  List<Object?> tableBindings(String table) => <Object?>[table];

  /// Query returning one row when the table exists ([tableBindings]).
  String compileTableExists();

  /// Query returning one row when the view exists ([tableBindings]).
  String compileViewExists();

  /// Query listing user table names (column `name`).
  String compileListTables();

  /// Query returning raw column rows of a table ([tableBindings]).
  String compileColumns();

  /// Normalizes a raw column row from [compileColumns].
  ColumnInfo columnInfo(Map<String, Object?> row);

  /// `ALTER TABLE ... RENAME TO ...` for `Schema.rename`.
  String compileRename(String from, String to) =>
      'ALTER TABLE ${wrap(from)} RENAME TO ${wrap(to)}';

  /// `DROP TABLE IF EXISTS` for `Schema.dropIfExists`.
  String compileDropIfExists(String table) =>
      'DROP TABLE IF EXISTS ${wrap(table)}';

  /// `DROP TABLE` for `Schema.drop`.
  String compileDrop(String table) => 'DROP TABLE ${wrap(table)}';

  /// Drops the index [name] of [table].
  String compileDropIndex(String table, String name) =>
      'DROP INDEX ${wrap(name)}';

  /// Drops the foreign key [name] of [table].
  String compileDropForeign(String table, String name) =>
      'ALTER TABLE ${wrap(table)} DROP CONSTRAINT ${wrap(name)}';

  /// [value] as a SQL literal in a `DEFAULT` clause: strings quoted with
  /// quotes doubled, booleans as `1` or `0`.
  String literal(Object? value) => switch (value) {
    null => 'NULL',
    bool() => value ? '1' : '0',
    num() => '$value',
    _ => "'${'$value'.replaceAll("'", "''")}'",
  };

  // --- shared compilation ----------------------------------------------------

  /// `name TYPE [NULL|NOT NULL] [DEFAULT ...] [UNIQUE] [PRIMARY KEY]`.
  String compileColumn(ColumnDefinition column) {
    final buffer = StringBuffer()
      ..write(wrap(column.name))
      ..write(' ')
      ..write(typeFor(column));
    if (supportsUnsigned && column.isUnsigned && !column.isAutoIncrement) {
      buffer.write(' UNSIGNED');
    }
    if (column.isAutoIncrement) {
      buffer.write(autoIncrementClause);
      return buffer.toString();
    }
    buffer.write(column.isNullable ? ' NULL' : ' NOT NULL');
    buffer.write(defaultClause(column));
    if (column.isUnique && inlineUnique) {
      buffer.write(' UNIQUE');
    }
    if (column.isPrimary) {
      buffer.write(' PRIMARY KEY');
    }
    if (column.type == .enumeration && enumAsCheck) {
      buffer.write(
        ' CHECK (${wrap(column.name)} IN (${column.allowed.map(literal).join(', ')}))',
      );
    }
    return buffer.toString();
  }

  /// The `DEFAULT` clause of [column], or an empty string without one.
  String defaultClause(ColumnDefinition column) {
    if (column.usesCurrent) {
      return ' DEFAULT CURRENT_TIMESTAMP';
    }
    if (column.rawDefault != null) {
      return ' DEFAULT ${column.rawDefault}';
    }
    if (column.hasDefault) {
      return ' DEFAULT ${literal(column.defaultValue)}';
    }
    return '';
  }

  /// Inline `CONSTRAINT ... FOREIGN KEY` clause.
  String compileForeignClause(String table, ForeignKeyDefinition key) {
    final target = key.referencedTable;
    if (target == null) {
      throw StateError(
        'Foreign key on [${key.columns.join(', ')}] is missing .on(table).',
      );
    }
    final buffer = StringBuffer(
      'CONSTRAINT ${wrap(key.nameFor(table))} FOREIGN KEY (${key.columns.map(wrap).join(', ')}) '
      'REFERENCES ${wrap(target)} (${key.referencedColumns.map(wrap).join(', ')})',
    );
    if (key.onDeleteAction != null) {
      buffer.write(' ON DELETE ${key.onDeleteAction}');
    }
    if (key.onUpdateAction != null) {
      buffer.write(' ON UPDATE ${key.onUpdateAction}');
    }
    return buffer.toString();
  }

  /// `CREATE [UNIQUE] INDEX` for [index] on [table].
  String compileIndex(String table, IndexDefinition index) => index.vector
      ? compileVectorIndex(table, index)
      : 'CREATE ${index.unique ? 'UNIQUE ' : ''}INDEX ${wrap(index.nameFor(table))} ON '
            '${wrap(table)} (${index.columns.map(wrap).join(', ')})';

  /// Whether [compileVectorIndex] gives a statement. Without it a vector index
  /// is left out, as SQLite does, or refused, as MySQL does.
  bool get skipsVectorIndex => false;

  /// The statement creating a vector [index]; dialects with one override it.
  String compileVectorIndex(String table, IndexDefinition index) =>
      throw UnsupportedError('Vector indexes need PostgreSQL or MariaDB.');

  /// Indexes implied by `.index()` / `.unique()` column modifiers.
  List<IndexDefinition> columnIndexes(Blueprint blueprint) => [
    for (final column in blueprint.addedColumns)
      if (column.hasIndex)
        IndexDefinition(
          [column.name],
          unique: false,
          vector: column.type == .vector,
        ),
    for (final column in blueprint.addedColumns)
      if (column.isUnique && !inlineUnique)
        IndexDefinition([column.name], unique: true),
  ];

  /// The statements creating [blueprint]'s table and its indexes.
  List<String> compileCreate(Blueprint blueprint) {
    final parts = <String>[
      for (final column in blueprint.columns) compileColumn(column),
      if (blueprint.primaryKey case final key?)
        'CONSTRAINT ${wrap(key.name!)} PRIMARY KEY '
            '(${key.columns.map(wrap).join(', ')})',
      for (final key in blueprint.foreignKeys)
        compileForeignClause(blueprint.table, key),
    ];
    return <String>[
      'CREATE TABLE ${wrap(blueprint.table)} (${parts.join(', ')})$createSuffix',
      for (final index in [...columnIndexes(blueprint), ...blueprint.indexes])
        if (!index.vector || !skipsVectorIndex)
          compileIndex(blueprint.table, index),
    ];
  }

  /// Text appended to `CREATE TABLE`, such as MySQL's engine and charset.
  String get createSuffix => '';

  /// ALTER statements for [blueprint] (PostgreSQL/MySQL style; SQLite uses
  /// [SqliteTableRebuilder] when needed).
  List<String> compileAlter(Blueprint blueprint) {
    final table = wrap(blueprint.table);
    return <String>[
      for (final name in blueprint.dropForeignKeys)
        compileDropForeign(blueprint.table, name),
      for (final name in blueprint.dropIndexes)
        compileDropIndex(blueprint.table, name),
      for (final name in blueprint.dropColumns)
        'ALTER TABLE $table DROP COLUMN ${wrap(name)}',
      for (final (from, to) in blueprint.renameColumns)
        'ALTER TABLE $table RENAME COLUMN ${wrap(from)} TO ${wrap(to)}',
      for (final column in blueprint.addedColumns)
        'ALTER TABLE $table ADD COLUMN ${compileColumn(column)}',
      for (final column in blueprint.changedColumns)
        ...compileChange(blueprint.table, column),
      for (final key in blueprint.foreignKeys)
        'ALTER TABLE $table ADD ${compileForeignClause(blueprint.table, key)}',
      for (final index in [...columnIndexes(blueprint), ...blueprint.indexes])
        if (!index.vector || !skipsVectorIndex)
          compileIndex(blueprint.table, index),
    ];
  }

  /// Statements altering an existing column to match [column].
  List<String> compileChange(String table, ColumnDefinition column);
}
