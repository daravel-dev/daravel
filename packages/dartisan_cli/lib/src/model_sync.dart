import 'package:daravel/daravel.dart';

import 'generator.dart';

/// What `model:sync` needs from a model source file.
final class ModelSource {
  /// What `model:sync` reads from a model file.
  const ModelSource({
    required this.className,
    required this.table,
    required this.casts,
    required this.primaryKey,
    required this.authenticatable,
    this.defaults = const <String>{},
  });

  /// Parses `final class X extends Model`, `table: '...'`, the casts map
  /// and the primary key (regex-based; generated layout assumed).
  static ModelSource? parse(String source) {
    final className = RegExp(r'class\s+(\w+)\s+extends\s+Model\b')
        .firstMatch(source)
        ?.group(1);
    final table = RegExp(r"table:\s*'([^']+)'").firstMatch(source)?.group(1);
    if (className == null || table == null) {
      return null;
    }
    final casts = <String, String>{
      for (final m in RegExp(r"'(\w+)'\s*:\s*Cast\.(\w+)").allMatches(source))
        m.group(1)!: m.group(2)!,
    };
    final primaryKey =
        RegExp(r"primaryKey:\s*'([^']+)'").firstMatch(source)?.group(1) ?? 'id';
    final attributes = RegExp(
      r'\battributes:\s*(?:const\s*)?(?:<[^>]*>\s*)?\{([^}]*)\}',
    ).firstMatch(source)?.group(1);
    return ModelSource(
      className: className,
      table: table,
      casts: casts,
      primaryKey: primaryKey,
      authenticatable: source.contains('AuthenticatableModel'),
      defaults: {
        if (attributes != null)
          for (final m in RegExp(r"'(\w+)'\s*:").allMatches(attributes))
            m.group(1)!,
      },
    );
  }

  /// The model's class name.
  final String className;

  /// Its table.
  final String table;

  /// Its casts, by column.
  final Map<String, String> casts;

  /// Its primary key.
  final String primaryKey;

  /// Whether it is an authenticatable user.
  final bool authenticatable;

  /// The columns its `attributes:` map gives a default.
  final Set<String> defaults;
}

/// Accessor names that would clash with `Model`/`Authenticatable` members
/// or Dart keywords; those columns are skipped with a warning.
const Set<String> reservedAccessors = <String>{
  'key',
  'table',
  'attributes',
  'original',
  'relations',
  'exists',
  'pivot',
  'database',
  'modelDefinition',
  'wasRecentlyCreated',
  'hashCode',
  'runtimeType',
  'authIdentifier',
  'authIdentifierName',
  'authPassword',
  'authPasswordName',
  'rememberToken',
  'class',
  'default',
  'new',
  'switch',
  'case',
  'if',
  'else',
  'for',
  'while',
  'do',
  'return',
  'var',
  'final',
  'const',
  'void',
  'null',
  'true',
  'false',
  'this',
  'super',
  'is',
  'in',
  'try',
  'catch',
  'throw',
  'enum',
  'extends',
  'with',
  'assert',
  'break',
  'continue',
  'rethrow',
};

/// Result of rendering the accessor region.
final class AccessorPlan {
  /// The accessor [lines] to write, and [warnings] about columns skipped.
  const AccessorPlan(this.lines, this.warnings);

  /// The accessor lines.
  final List<String> lines;

  /// What could not be generated.
  final List<String> warnings;
}

/// The scale of `decimal(8,2)` / `NUMERIC(8, 2)`.
final RegExp _decimalScale = RegExp(r'\(\s*\d+\s*,\s*(\d+)\s*\)');

/// Maps a column to a Dart type: casts win, then the database type.
/// Booleans, dates and JSON without a cast stay raw (with a hint) on SQLite
/// and MySQL, which return them as integers and strings; PostgreSQL returns
/// them as Dart values. A decimal without a cast is `Object?`: MySQL returns
/// it as a string and SQLite as a number, so no one type holds for both.
({String type, String? hint}) dartTypeFor(
  ColumnInfo column,
  String? cast, {
  SqlDialect dialect = SqlDialect.sqlite,
}) {
  switch (cast) {
    case 'dateTime' || 'date' || 'immutableDateTime' || 'dateTimeFormat':
      return (type: 'DateTime', hint: null);
    case 'boolean' || 'bool':
      return (type: 'bool', hint: null);
    case 'integer' || 'int':
      return (type: 'int', hint: null);
    case 'double' || 'float' || 'decimal':
      return (type: 'double', hint: null);
    case 'decimalString':
      return (type: 'String', hint: null);
    case 'json' || 'array' || 'map':
      return (type: 'Object', hint: null);
    case 'string':
      return (type: 'String', hint: null);
  }
  if (dialect == SqlDialect.postgres) {
    return (type: _postgresType(column.type.toLowerCase()), hint: null);
  }
  final t = column.type.toLowerCase();
  if (t.contains('bool')) {
    return (type: 'Object', hint: 'add Cast.boolean for a bool accessor');
  }
  if (t.contains('int') || t == 'serial' || t == 'bigserial') {
    return (type: 'int', hint: null);
  }
  if (t.contains('real') || t.contains('floa') || t.contains('doub')) {
    return (type: 'double', hint: null);
  }
  if (t.startsWith('decimal') || t.startsWith('numeric')) {
    final places = _decimalScale.firstMatch(t)?.group(1) ?? '2';
    return (
      type: 'Object',
      hint:
          'add Cast.decimalString($places) for a String accessor, as '
          "Laravel's decimal:$places (MySQL returns a string, SQLite a number)",
    );
  }
  if (t.contains('date') || t.contains('time')) {
    return (type: 'String', hint: 'add Cast.dateTime for a DateTime accessor');
  }
  if (t.contains('json')) {
    return (type: 'Object', hint: 'add Cast.json for decoded access');
  }
  if (t.contains('blob') || t.contains('bytea') || t.contains('binary')) {
    return (type: 'List<int>', hint: null);
  }
  return (type: 'String', hint: null);
}

/// What the PostgreSQL driver returns for a column of [dataType]
/// (`information_schema.columns.data_type`); `Object` for the types without
/// a plain Dart value (`time`, `interval`, arrays, enums).
String _postgresType(String dataType) => switch (dataType) {
  'boolean' => 'bool',
  'smallint' || 'integer' || 'bigint' => 'int',
  'real' || 'double precision' => 'double',
  'numeric' => 'String',
  'date' ||
  'timestamp without time zone' ||
  'timestamp with time zone' => 'DateTime',
  'character varying' ||
  'character' ||
  'text' ||
  'uuid' ||
  'inet' ||
  'cidr' ||
  'macaddr' => 'String',
  'macaddr8' => 'String',
  'bytea' => 'List<int>',
  _ => 'Object',
};

/// Accessor lines for [columns] (getters for all, setters except for the
/// primary key and timestamps), typed for the [dialect] the columns come
/// from.
AccessorPlan planAccessors(
  ModelSource model,
  List<ColumnInfo> columns, {
  SqlDialect dialect = SqlDialect.sqlite,
}) {
  final lines = <String>[];
  final warnings = <String>[];
  const readOnly = {'created_at', 'updated_at', 'deleted_at'};
  for (final column in columns) {
    final getter = Naming.camel(column.name);
    if (getter.isEmpty || reservedAccessors.contains(getter)) {
      warnings.add(
        'Skipped column [${column.name}]: accessor `$getter` clashes with a '
        'Model member or keyword.',
      );
      continue;
    }
    final mapped = dartTypeFor(
      column,
      model.casts[column.name],
      dialect: dialect,
    );
    if (mapped.hint != null) {
      warnings.add('Column [${column.name}]: ${mapped.hint}.');
    }
    final type = mapped.type == 'Object'
        ? 'Object?'
        : (column.nullable ? '${mapped.type}?' : mapped.type);
    if (column.defaultValue != null &&
        !type.endsWith('?') &&
        !column.autoIncrement &&
        column.name != model.primaryKey &&
        !model.defaults.contains(column.name)) {
      warnings.add(
        'Column [${column.name}] has a database default that a model made '
        'with create() does not see: `$getter` throws until refresh(). '
        "Declare it in ModelDefinition(attributes: {'${column.name}': ...}).",
      );
    }
    lines.add("  $type get $getter => getAttr('${column.name}');");
    final writable =
        column.name != model.primaryKey && !readOnly.contains(column.name);
    if (writable) {
      lines.add(
        "  set $getter($type value) => setAttr('${column.name}', value);",
      );
    }
  }
  return AccessorPlan(lines, warnings);
}

const String _accessorsStart = '// <dartisan:accessors>';
const String _accessorsEnd = '// </dartisan:accessors>';

/// Replaces the accessor region of [source]; `null` when the markers are
/// missing.
String? replaceAccessors(String source, List<String> lines) {
  final start = source.indexOf(_accessorsStart);
  final end = source.indexOf(_accessorsEnd);
  if (start == -1 || end == -1 || end < start) {
    return null;
  }
  final lineStart = source.lastIndexOf('\n', end - 1) + 1;
  final indent = source.substring(lineStart, end);
  return '${source.substring(0, start + _accessorsStart.length)}\n'
      '${lines.join('\n')}\n'
      '${indent.trim().isEmpty ? indent : ''}'
      '${source.substring(end)}';
}

const String _staticsStart = '// <dartisan:statics>';
const String _staticsEnd = '// </dartisan:statics>';

/// The query shortcuts `make:model` writes into the statics region of
/// [className] (`User.find(1)`, `User.where(...)`).
List<String> staticLines(String className) => [
  '  static ModelQuery<$className> query() => definition.query();',
  '  static Future<$className?> find(Object id) => query().find(id);',
  '  static Future<$className> findOrFail(Object id) => '
      'query().findOrFail(id);',
  '  static Future<$className> create(Map<String, Object?> attributes) =>',
  '      query().create(attributes);',
  '  static Future<ModelCollection<$className>> all() => query().get();',
  '  static ModelQuery<$className> where(Object column, '
      '[Object? op, Object? value]) =>',
  '      query().where(column, op, value);',
];

/// Fills an empty statics region of [source] with [staticLines]. A region
/// that holds anything belongs to the application and is left alone, as is
/// a source without the markers: both return [source] unchanged.
String fillStatics(String source, String className) {
  final start = source.indexOf(_staticsStart);
  final end = source.indexOf(_staticsEnd);
  if (start == -1 || end == -1 || end < start) {
    return source;
  }
  if (source.substring(start + _staticsStart.length, end).trim().isNotEmpty) {
    return source;
  }
  final lineStart = source.lastIndexOf('\n', end - 1) + 1;
  final indent = source.substring(lineStart, end);
  return '${source.substring(0, start + _staticsStart.length)}\n'
      '${staticLines(className).join('\n')}\n'
      '${indent.trim().isEmpty ? indent : ''}'
      '${source.substring(end)}';
}
