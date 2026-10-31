import 'package:daravel/daravel.dart';

import 'generator.dart';

/// What `model:sync` needs from a model source file.
final class ModelSource {
  const ModelSource({
    required this.className,
    required this.table,
    required this.casts,
    required this.primaryKey,
    required this.authenticatable,
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
    return ModelSource(
      className: className,
      table: table,
      casts: casts,
      primaryKey: primaryKey,
      authenticatable: source.contains('AuthenticatableModel'),
    );
  }

  final String className;
  final String table;
  final Map<String, String> casts;
  final String primaryKey;
  final bool authenticatable;
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
  const AccessorPlan(this.lines, this.warnings);

  final List<String> lines;
  final List<String> warnings;
}

/// Maps a column to a Dart type: casts win, then the database type.
/// Booleans, dates and JSON without a cast stay raw (with a hint) on SQLite
/// and MySQL, which return them as integers and strings; PostgreSQL returns
/// them as Dart values.
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
/// a plain Dart value (`time`, `interval`, `inet`, arrays, enums).
String _postgresType(String dataType) => switch (dataType) {
  'boolean' => 'bool',
  'smallint' || 'integer' || 'bigint' => 'int',
  'real' || 'double precision' => 'double',
  'numeric' => 'String',
  'date' ||
  'timestamp without time zone' ||
  'timestamp with time zone' => 'DateTime',
  'character varying' || 'character' || 'text' || 'uuid' => 'String',
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
