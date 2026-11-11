import 'package:daravel/daravel.dart';

import 'generator.dart';
import 'stubs.dart';

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
    this.relations = const <ModelRelation>[],
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
      relations: [
        for (final m in _relationEntry.allMatches(source))
          (name: m.group(1)!, kind: m.group(2)!, related: m.group(3)),
      ],
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

  /// Its relations, from `relations: {'posts': () => HasMany<Post>(...)}`.
  final List<ModelRelation> relations;
}

/// One entry of a model's `relations:` map: its [name], the relation class
/// ([kind], `HasMany`) and the [related] model (null for `MorphTo`).
typedef ModelRelation = ({String name, String kind, String? related});

/// `'posts': () => HasMany<Post>(`, as `make:model` and the guide write it.
final RegExp _relationEntry = RegExp(
  r"'(\w+)'\s*:\s*\(\)\s*=>\s*(HasMany|HasOne|BelongsToMany|BelongsTo|"
  r"HasManyThrough|HasOneThrough|MorphMany|MorphOne|MorphToMany|MorphedByMany|"
  r"MorphTo)(?:<(\w+)>)?\(",
);

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

/// The members of `Object`, which a record field may not be named after.
const Set<String> _objectMembers = <String>{
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
};

/// Dart's reserved words, which are not identifiers at all.
const Set<String> _reservedWords = <String>{
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

/// What `model:sync` names one column: its accessor [getter] (null when the
/// column gets none) and its [field] in the `cols` record.
typedef ColumnNames = ({ColumnInfo column, String? getter, String field});

/// The names of [columns], from one rule so `user.x` and `User.cols.x`
/// always mean the same column: a column whose camelCase name is free and
/// not reserved gets that name as its accessor and its `cols` field. The
/// others (a `Model` member, a keyword, a name an earlier column took) get
/// no accessor, and a `cols` field from [Naming.camel] made valid for a
/// record: `c` before a leading digit, `Column` after an `Object` member, a
/// reserved word or a taken name, then a number until it is free. The
/// result follows the order of [columns], so it is the same on every sync.
List<ColumnNames> columnNames(List<ColumnInfo> columns) {
  final taken = <String>{};
  final getters = <String?>[
    for (final column in columns)
      switch (Naming.camel(column.name)) {
        final name
            when _identifier.hasMatch(name) &&
                !reservedAccessors.contains(name) &&
                !_objectMembers.contains(name) &&
                taken.add(name) =>
          name,
        _ => null,
      },
  ];
  return [
    for (var i = 0; i < columns.length; i++)
      (
        column: columns[i],
        getter: getters[i],
        field: getters[i] ?? _freeField(Naming.camel(columns[i].name), taken),
      ),
  ];
}

/// A Dart identifier that is not private (no leading `_` or digit).
final RegExp _identifier = RegExp(r'^[A-Za-z$][A-Za-z0-9_$]*$');

String _freeField(String camel, Set<String> taken) {
  var base = camel.isEmpty ? 'column' : camel;
  if (RegExp(r'^[0-9]').hasMatch(base)) {
    base = 'c$base';
  }
  if (_objectMembers.contains(base) || _reservedWords.contains(base)) {
    base = '${base}Column';
  }
  var name = base;
  if (taken.contains(name)) {
    name = '${base}Column';
  }
  for (var n = 2; taken.contains(name); n++) {
    name = '${base}Column$n';
  }
  taken.add(name);
  return name;
}

/// The Dart type `model:sync` gives [column] of [model]: its cast or
/// database type, nullable as the column is; [idType] for the primary key
/// with `--typed-ids`.
String columnType(
  ModelSource model,
  ColumnInfo column, {
  SqlDialect dialect = SqlDialect.sqlite,
  String? idType,
}) {
  if (idType != null && column.name == model.primaryKey) {
    return idType;
  }
  final mapped = dartTypeFor(
    column,
    model.casts[column.name],
    dialect: dialect,
  );
  return mapped.type == 'Object'
      ? 'Object?'
      : (column.nullable ? '${mapped.type}?' : mapped.type);
}

/// The `static const cols = (...)` lines of [model] for [names]: one typed
/// column token per column (`User.cols.email`). Empty without columns.
List<String> colsLines(
  ModelSource model,
  List<ColumnNames> names, {
  SqlDialect dialect = SqlDialect.sqlite,
  String? idType,
}) => names.isEmpty
    ? const <String>[]
    : [
        '  /// The columns of `${model.table}`, for typed queries: '
            '`${model.className}.cols.${names.first.field}`.',
        '  static const cols = (',
        for (final (:column, getter: _, :field) in names)
          '    $field: ModelColumn<${model.className}, '
              '${columnType(model, column, dialect: dialect, idType: idType)}>'
              "('${column.name}'),",
        '  );',
      ];

/// Accessor lines for [columns] (getters for all, setters except for the
/// primary key and timestamps), typed for the [dialect] the columns come
/// from, after the `cols` record of [colsLines]. With [idType]
/// (`--typed-ids`) the primary key getter returns that extension type
/// instead.
AccessorPlan planAccessors(
  ModelSource model,
  List<ColumnInfo> columns, {
  SqlDialect dialect = SqlDialect.sqlite,
  String? idType,
}) {
  final names = columnNames(columns);
  final lines = <String>[
    ...colsLines(model, names, dialect: dialect, idType: idType),
  ];
  final warnings = <String>[];
  const readOnly = {'created_at', 'updated_at', 'deleted_at'};
  for (final (:column, :getter, :field) in names) {
    if (getter == null) {
      final camel = Naming.camel(column.name);
      warnings.add(
        names.any((other) => other.getter == camel)
            ? 'Skipped column [${column.name}]: accessor `$camel` is '
                  'already the accessor of another column; use '
                  '${model.className}.cols.$field.'
            : 'Skipped column [${column.name}]: accessor `$camel` clashes '
                  'with a Model member or keyword, or is not a Dart name; '
                  'use ${model.className}.cols.$field.',
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
    final type = columnType(model, column, dialect: dialect, idType: idType);
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
  final relations = relationLines(model, {for (final n in names) ?n.getter});
  lines.addAll(relations.lines);
  warnings.addAll(relations.warnings);
  return AccessorPlan(lines, warnings);
}

/// The relation classes whose result is a collection; the others give one
/// model or null.
const Set<String> _manyRelations = {
  'HasMany',
  'BelongsToMany',
  'HasManyThrough',
  'MorphMany',
  'MorphToMany',
  'MorphedByMany',
};

/// The `static const rels = (...)` record of [model] (`User.rels.posts`),
/// then a typed getter (`user.posts`) and loader (`user.loadPosts()`) per
/// relation. A relation whose name is not a Dart name, is reserved, or is
/// already a column accessor in [columnGetters] is left out with a warning;
/// a loader that would clash with a `Model` member (`loadMissing`) is left
/// out alone.
AccessorPlan relationLines(ModelSource model, Set<String> columnGetters) {
  final kept = <ModelRelation>[];
  final warnings = <String>[];
  for (final relation in model.relations) {
    final name = relation.name;
    if (!_identifier.hasMatch(name) ||
        reservedAccessors.contains(name) ||
        _objectMembers.contains(name) ||
        _reservedWords.contains(name)) {
      warnings.add(
        'Skipped relation [$name]: not a Dart name, or it clashes with a '
        'Model member or keyword.',
      );
    } else if (columnGetters.contains(name)) {
      warnings.add(
        'Skipped relation [$name]: `$name` is already a column accessor.',
      );
    } else {
      kept.add(relation);
    }
  }
  if (kept.isEmpty) {
    return AccessorPlan(const [], warnings);
  }
  final className = model.className;
  String related(ModelRelation r) => r.related ?? 'Model';
  final lines = <String>[
    '  /// The relations of `$className`, for typed eager loading: '
        '`$className.rels.${kept.first.name}`.',
    '  static const rels = (',
    for (final r in kept)
      "    ${r.name}: RelationToken<$className, ${related(r)}>('${r.name}'),",
    '  );',
  ];
  for (final r in kept) {
    final many = _manyRelations.contains(r.kind);
    final type = many ? 'ModelCollection<${related(r)}>' : '${related(r)}?';
    lines.add("  $type get ${r.name} => related('${r.name}');");
    final loader = 'load${r.name[0].toUpperCase()}${r.name.substring(1)}';
    if (loader == 'loadMissing') {
      warnings.add(
        'Relation [${r.name}]: no $loader() (Model.loadMissing); use '
        'load([$className.rels.${r.name}]).',
      );
      continue;
    }
    lines
      ..add('  Future<$type> $loader() async {')
      ..add('    await load([rels.${r.name}]);')
      ..add('    return ${r.name};')
      ..add('  }');
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
/// [className] (`User.find(1)`, `User.where(...)`). With [idType]
/// (`--typed-ids`), `find` and `findOrFail` take that type.
List<String> staticLines(String className, {String? idType}) => [
  '  static ModelQuery<$className> query() => definition.query();',
  '  static Future<$className?> find(${idType ?? 'Object'} id) => '
      'query().find(id);',
  '  static Future<$className> findOrFail(${idType ?? 'Object'} id) => '
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
String fillStatics(String source, String className, {String? idType}) {
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
      '${staticLines(className, idType: idType).join('\n')}\n'
      '${indent.trim().isEmpty ? indent : ''}'
      '${source.substring(end)}';
}

/// `find(Object id)` and `findOrFail(Object id)` as `make:model` writes them.
final RegExp _untypedFinders = RegExp(
  r'(\b(?:find|findOrFail)\(\s*)Object(\s+id\s*\))',
);

/// Retypes the generated `find(Object id)` and `findOrFail(Object id)` of
/// the statics region of [source] to take [idType] (`--typed-ids`). Other
/// statics, and code outside the region, are left alone.
String typeStatics(String source, String idType) {
  final start = source.indexOf(_staticsStart);
  final end = source.indexOf(_staticsEnd);
  if (start == -1 || end == -1 || end < start) {
    return source;
  }
  final region = source
      .substring(start, end)
      .replaceAllMapped(
        _untypedFinders,
        (m) => '${m.group(1)}$idType${m.group(2)}',
      );
  return '${source.substring(0, start)}$region${source.substring(end)}';
}

const String _idsStart = '// <dartisan:ids>';
const String _idsEnd = '// </dartisan:ids>';

/// The name of [className]'s typed id (`UserId`).
String idTypeName(String className) => '${className}Id';

/// The typed id of [model] for `--typed-ids`: the representation (`int` or
/// `String`) of its primary key among [columns], or a [warning] when the
/// key has no column or another type.
({String? representation, String? warning}) typedIdRepresentation(
  ModelSource model,
  List<ColumnInfo> columns, {
  SqlDialect dialect = SqlDialect.sqlite,
}) {
  for (final column in columns) {
    if (column.name != model.primaryKey) {
      continue;
    }
    final type = dartTypeFor(
      column,
      model.casts[column.name],
      dialect: dialect,
    ).type;
    if (type == 'int' || type == 'String') {
      return (representation: type, warning: null);
    }
    return (
      representation: null,
      warning:
          'Primary key [${model.primaryKey}] is a $type, not an int or a '
          'String: no typed id.',
    );
  }
  return (
    representation: null,
    warning: 'No column for primary key [${model.primaryKey}]: no typed id.',
  );
}

/// The values the `model.id` stub is rendered with.
Map<String, String> idStubValues(String className, String representation) => {
  'class': className,
  'idType': representation,
  'idParse': representation == 'int'
      ? 'int.parse(raw)'
      : "raw.isEmpty ? throw const FormatException('Empty id.') : raw",
};

/// Replaces the `<dartisan:ids>` region of [source] with [code], or appends
/// the region at the end of the file when it has none (extension types are
/// top-level declarations, so the region sits outside the class).
String replaceIds(String source, String code) {
  final body = code.trimRight();
  final start = source.indexOf(_idsStart);
  final end = source.indexOf(_idsEnd);
  if (start != -1 && end > start) {
    return '${source.substring(0, start + _idsStart.length)}\n'
        '$body\n'
        '${source.substring(end)}';
  }
  final base = source.endsWith('\n') ? source : '$source\n';
  return '$base\n$_idsStart\n$body\n$_idsEnd\n';
}

/// What `model:sync` makes of one model file.
typedef ModelSync = ({
  String? source,
  AccessorPlan plan,
  List<String> warnings,
});

/// Syncs [source] (a model file parsed as [model]) with its table's
/// [columns]: fills an empty statics region and rewrites the accessors.
/// With [idStub] (the `model.id` template, `--typed-ids`), also writes the
/// typed id into the `<dartisan:ids>` region and types the primary key
/// getter, `find` and `findOrFail` with it. Without it the result is the
/// same as before typed ids existed. `source` is `null` when the file has
/// no accessors region.
ModelSync syncModelSource(
  String source,
  ModelSource model,
  List<ColumnInfo> columns, {
  SqlDialect dialect = SqlDialect.sqlite,
  String? idStub,
}) {
  final warnings = <String>[];
  String? idType;
  var next = source;
  if (idStub != null) {
    final typed = typedIdRepresentation(model, columns, dialect: dialect);
    if (typed.warning != null) {
      warnings.add(typed.warning!);
    }
    final representation = typed.representation;
    if (representation != null) {
      idType = idTypeName(model.className);
      next = replaceIds(
        typeStatics(fillStatics(next, model.className, idType: idType), idType),
        renderStub(idStub, idStubValues(model.className, representation)),
      );
    }
  }
  if (idType == null) {
    next = fillStatics(next, model.className);
  }
  final plan = planAccessors(model, columns, dialect: dialect, idType: idType);
  warnings.insertAll(0, plan.warnings);
  return (
    source: replaceAccessors(next, plan.lines),
    plan: plan,
    warnings: warnings,
  );
}
