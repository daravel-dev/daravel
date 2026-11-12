import 'package:daravel/daravel.dart';

import 'generator.dart';
import 'region_format.dart';
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
    this.fillable = const <String>[],
    this.guarded = const <String>['*'],
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
      fillable: _stringList(source, 'fillable') ?? const <String>[],
      guarded: _stringList(source, 'guarded') ?? const <String>['*'],
    );
  }

  /// The strings of the `[key]: [...]` list in [source], or null when it
  /// declares none.
  static List<String>? _stringList(String source, String key) {
    final list = RegExp(
      '\\b$key:\\s*(?:const\\s*)?(?:<String>\\s*)?\\[([^\\]]*)\\]',
    ).firstMatch(source)?.group(1);
    return list == null
        ? null
        : [for (final m in RegExp(r"'([^']*)'").allMatches(list)) m.group(1)!];
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

  /// Its `fillable:` list (empty when not declared).
  final List<String> fillable;

  /// Its `guarded:` list (`['*']` when not declared).
  final List<String> guarded;

  /// Whether [column] may be mass assigned, as `ModelDefinition.isFillable`.
  bool isFillable(String column) {
    if (fillable.contains(column)) {
      return true;
    }
    if (fillable.isNotEmpty) {
      return false;
    }
    return !guarded.contains('*') && !guarded.contains(column);
  }
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
  // The static records model:sync writes: an instance member of the same
  // name does not compile.
  'cols',
  'rels',
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
  final writes = typedWriteLines(
    model,
    names,
    dialect: dialect,
    idType: idType,
  );
  lines.addAll(writes.lines);
  warnings.addAll(writes.warnings);
  final relations = relationLines(model, {for (final n in names) ?n.getter});
  lines.addAll(relations.lines);
  warnings.addAll(relations.warnings);
  return AccessorPlan(lines, warnings);
}

/// The loaders `Model` has; a relation loader of the same name would
/// hide them.
const Set<String> _modelLoaders = {'load', 'loadMissing'};

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

/// The relations of [model] that get a `rels` entry, and why the others do
/// not: a name that is not a Dart name, is reserved, or is already a column
/// accessor in [columnGetters].
({List<ModelRelation> kept, List<String> warnings}) _typedRelations(
  ModelSource model,
  Set<String> columnGetters,
) {
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
  return (kept: kept, warnings: warnings);
}

/// The relation path extension of [model] (Blueprint #155 Rev. 1): one
/// getter per relation with a `rels` entry, on any relation path that ends
/// at [model], so `User.rels.posts.comments` is `posts.comments`, checked
/// at each step. A relation named like a member of `RelationToken`
/// ([relationTokenMembers]) gets no getter, since the member would always
/// win, and a warning; `nested(...)` reaches it. A `MorphTo` relation gets
/// a getter whose model is `Model`, where the path stops: no extension is
/// ever written on `RelationToken<Root, Model>`.
///
/// [AccessorPlan.lines] is the top-level code for the
/// `<dartisan:relation-path>` region, empty when no relation qualifies.
AccessorPlan relationPathPlan(ModelSource model, Set<String> columnGetters) {
  final (:kept, warnings: _) = _typedRelations(model, columnGetters);
  final warnings = <String>[];
  final getters = <ModelRelation>[];
  for (final relation in kept) {
    if (relationTokenMembers.contains(relation.name)) {
      warnings.add(
        'Relation [${relation.name}]: no relation path getter, since '
        '`${relation.name}` is a member of RelationToken; use '
        '.nested(${model.className}.rels.${relation.name}).',
      );
    } else {
      getters.add(relation);
    }
  }
  if (getters.isEmpty) {
    return AccessorPlan(const [], warnings);
  }
  final className = model.className;
  // The type parameter must not hide a type the extension names: a model
  // called Root would otherwise read RelationToken<Root, Root>.
  final named = {className, for (final r in getters) r.related ?? 'Model'};
  var root = 'Root';
  for (var n = 1; named.contains(root); n++) {
    root = n == 1 ? 'PathRoot' : 'PathRoot$n';
  }
  return AccessorPlan([
    '/// The relations of [$className] after any relation path that ends at',
    '/// one: the path, then `${getters.first.name}` (written by `dartisan '
        'model:sync`',
    '/// from `$className.rels`).',
    'extension ${className}RelationPath<$root extends Model>',
    '    on RelationToken<$root, $className> {',
    for (final (i, r) in getters.indexed) ...[
      if (i > 0) '',
      '  /// The path, then `${r.name}`: `<path>.${r.name}`.',
      '  RelationToken<$root, ${r.related ?? 'Model'}> get ${r.name} =>',
      '      nested($className.rels.${r.name});',
    ],
    '}',
  ], warnings);
}

/// Whether [source], a model file, has the relation path extension of
/// [className], whatever its type parameter is named.
bool hasRelationPath(String source, String className) =>
    source.contains('extension ${className}RelationPath<');

/// The keys of the `relations:` map of [source] that [ModelSource.parse]
/// did not read as a relation (a closure with a body, a relation built by a
/// helper): they get no `rels` entry, getter or path, and `model:sync`
/// says so instead of leaving them out silently.
List<String> unreadRelations(String source, ModelSource model) {
  final read = {for (final r in model.relations) r.name};
  return [
    for (final key in _relationKeys(source))
      if (!read.contains(key)) key,
  ];
}

/// The string keys at the top level of the `relations: {...}` map.
///
/// A light scan, enough for a warning: it skips line comments and plain
/// quoted strings, but not block comments (`/* ... */`) or raw and
/// triple-quoted strings, where a quote or bracket can mislead it.
List<String> _relationKeys(String source) {
  final start = RegExp(r'\brelations:\s*(?:const\s*)?(?:<[^>{]*>\s*)?\{')
      .firstMatch(source);
  if (start == null) {
    return const [];
  }
  final keys = <String>[];
  var depth = 1;
  var i = start.end;
  while (i < source.length && depth > 0) {
    final char = source[i];
    if (char == "'" || char == '"') {
      // A string literal; at the map's own level, followed by `:`, a key.
      final quote = char;
      final from = i + 1;
      i++;
      while (i < source.length && source[i] != quote) {
        i += source[i] == r'\' ? 2 : 1;
      }
      final text = source.substring(from, i.clamp(from, source.length));
      i++;
      if (depth == 1) {
        var j = i;
        while (j < source.length && source[j].trim().isEmpty) {
          j++;
        }
        if (j < source.length && source[j] == ':') {
          keys.add(text);
        }
      }
      continue;
    }
    if (char == '/' && i + 1 < source.length && source[i + 1] == '/') {
      // A line comment.
      final end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end;
      continue;
    }
    if (char == '{' || char == '(' || char == '[') {
      depth++;
    } else if (char == '}' || char == ')' || char == ']') {
      depth--;
    }
    i++;
  }
  return keys;
}

const String _relationPathStart = '// <dartisan:relation-path>';
const String _relationPathEnd = '// </dartisan:relation-path>';

/// Replaces the `<dartisan:relation-path>` region of [source] with [code]
/// (empty when the model has no relation for a path), or, when the file
/// has no region and [code] is not empty, appends the region after the
/// class: the extension is a top-level declaration.
String replaceRelationPath(String source, String code) {
  final body = code.trimRight();
  final start = source.indexOf(_relationPathStart);
  final end = source.indexOf(_relationPathEnd);
  if (start != -1 && end > start) {
    return '${source.substring(0, start + _relationPathStart.length)}\n'
        '${body.isEmpty ? '' : '$body\n'}'
        '${source.substring(end)}';
  }
  if (body.isEmpty) {
    return source;
  }
  final base = source.endsWith('\n') ? source : '$source\n';
  return '$base\n$_relationPathStart\n$body\n$_relationPathEnd\n';
}

/// The `static const rels = (...)` record of [model] (`User.rels.posts`),
/// then a typed getter (`user.posts`) and loader (`user.loadPosts()`) per
/// relation. A relation whose name is not a Dart name, is reserved, or is
/// already a column accessor in [columnGetters] is left out with a warning;
/// a loader that would clash with a `Model` member (`loadMissing`) is left
/// out alone.
AccessorPlan relationLines(ModelSource model, Set<String> columnGetters) {
  final (:kept, :warnings) = _typedRelations(model, columnGetters);
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
  // What a loader must not be: a Model loader, a column accessor, a
  // relation getter or an earlier loader (each would be a second member
  // of that name, which does not compile).
  final owners = <String, String>{
    for (final name in _modelLoaders) name: 'Model.$name',
    for (final getter in columnGetters) getter: 'the column accessor $getter',
    for (final r in kept) r.name: 'the relation ${r.name}',
  };
  for (final r in kept) {
    final many = _manyRelations.contains(r.kind);
    final type = many ? 'ModelCollection<${related(r)}>' : '${related(r)}?';
    lines.add("  $type get ${r.name} => related('${r.name}');");
    final loader = 'load${r.name[0].toUpperCase()}${r.name.substring(1)}';
    final owner = owners[loader];
    if (owner != null) {
      warnings.add(
        'Relation [${r.name}]: no $loader(), the name of $owner; use '
        'load([$className.rels.${r.name}]).',
      );
      continue;
    }
    owners[loader] = 'the loader of the relation ${r.name}';
    lines
      ..add('  Future<$type> $loader() async {')
      ..add('    await load([rels.${r.name}]);')
      ..add('    return ${r.name};')
      ..add('  }');
  }
  return AccessorPlan(lines, warnings);
}

/// `createWith`, `makeWith`, `fillWith` and `updateWith` of [model]: the
/// mass-assignable columns as typed named parameters (W9.13), through
/// `create`, `make`, `fill` and `update`, so fillable, events and
/// timestamps are those of the map forms.
///
/// A column is a parameter when it has an accessor, is not the primary key
/// or a timestamp, and is fillable under the model's `fillable:` and
/// `guarded:` lists as `ModelDefinition.isFillable` reads them, so `fill`
/// never drops one. It is `required` in `createWith`/`makeWith` when it is
/// `NOT NULL` with no database default and no `attributes:` default. In
/// `fillWith`/`updateWith` every parameter is optional, and a nullable
/// column is a [Patch] so it can be set to null. Without a fillable column
/// nothing is written, and [AccessorPlan.warnings] says why.
AccessorPlan typedWriteLines(
  ModelSource model,
  List<ColumnNames> names, {
  SqlDialect dialect = SqlDialect.sqlite,
  String? idType,
}) {
  const timestamps = {'created_at', 'updated_at', 'deleted_at'};
  final params = [
    for (final (:column, :getter, field: _) in names)
      if (getter != null &&
          column.name != model.primaryKey &&
          !timestamps.contains(column.name) &&
          model.isFillable(column.name))
        (
          column: column,
          getter: getter,
          type: columnType(model, column, dialect: dialect, idType: idType),
          required:
              !column.nullable &&
              column.defaultValue == null &&
              !column.autoIncrement &&
              !model.defaults.contains(column.name),
        ),
  ];
  final className = model.className;
  if (params.isEmpty) {
    return AccessorPlan(const [], [
      '$className: no fillable column (fillable: [], guarded: '
          "${model.guarded.map((g) => "'$g'").toList()}); createWith, makeWith, "
          'fillWith and updateWith not generated.',
    ]);
  }
  String base(String type) =>
      type.endsWith('?') ? type.substring(0, type.length - 1) : type;
  final createParams = [
    for (final p in params)
      p.required
          ? '    required ${base(p.type)} ${p.getter},'
          : '    ${base(p.type)}? ${p.getter},',
  ];
  final createMap = [
    for (final p in params)
      p.required
          ? "    '${p.column.name}': ${p.getter},"
          : "    '${p.column.name}': ?${p.getter},",
  ];
  final patchParams = [
    for (final p in params)
      p.column.nullable
          ? '    Patch<${base(p.type)}?> ${p.getter} = const Patch.absent(),'
          : '    ${base(p.type)}? ${p.getter},',
  ];
  final patchMap = [
    for (final p in params)
      p.column.nullable
          ? "    if (${p.getter}.isPresent) '${p.column.name}': "
                '${p.getter}.value,'
          : "    '${p.column.name}': ?${p.getter},",
  ];
  // Only a nullable column is a Patch parameter; the doc mentions Patch
  // only when there is one.
  final hasPatch = params.any((p) => p.column.nullable);
  return AccessorPlan([
    '  /// Creates and saves a `$className` (`create` with a map, checked by',
    '  /// the compiler): a `required` column has no default.',
    '  static Future<$className> createWith({',
    ...createParams,
    '  }) => definition.query().create(<String, Object?>{',
    ...createMap,
    '  });',
    '  /// [createWith] without saving (`make`).',
    '  static $className makeWith({',
    ...createParams,
    '  }) => definition.query().make(<String, Object?>{',
    ...createMap,
    '  });',
    if (hasPatch) ...[
      '  /// Fills the given columns (`fill`); `Patch(null)` sets a nullable',
      '  /// one to null.',
    ] else
      '  /// Fills the given columns (`fill`).',
    '  $className fillWith({',
    ...patchParams,
    '  }) {',
    '    fill(<String, Object?>{',
    ...patchMap.map((l) => '  $l'),
    '    });',
    '    return this;',
    '  }',
    if (hasPatch) ...[
      '  /// Updates the given columns and saves (`update`); `Patch(null)` sets',
      '  /// a nullable one to null.',
    ] else
      '  /// Updates the given columns and saves (`update`).',
    '  Future<bool> updateWith({',
    ...patchParams,
    '  }) => update(<String, Object?>{',
    ...patchMap,
    '  });',
  ], const []);
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
  ...whereStaticLines(className),
];

/// The `where` static of [className]. Its optional arguments default to
/// [QueryBuilder.absent], so `User.where('a', '<>')` (two arguments) and
/// `User.where('a', '<>', null)` (`IS NOT NULL`) reach the query builder
/// apart.
List<String> whereStaticLines(String className) => [
  '  static ModelQuery<$className> where(',
  '    Object column, [',
  '    Object? operatorOrValue = QueryBuilder.absent,',
  '    Object? value = QueryBuilder.absent,',
  '  ]) => query().where(column, operatorOrValue, value);',
];

/// A `where` static written before `QueryBuilder.absent` (Daravel 1.27 and
/// earlier): it passes `null` on for a left-out argument, so two and three
/// arguments look the same to the query builder.
final RegExp _nullForwardingWhere = RegExp(
  r'static\s+ModelQuery<\w+>\s+where\(\s*Object\s+\w+,\s*\[\s*Object\?\s+(\w+),'
  r'\s*Object\?\s+(\w+),?\s*\]\s*\)\s*=>\s*query\(\)\.where\(',
);

/// The warning `model:sync` prints for a model whose statics region still
/// holds a `where` static that passes `null` on, with the lines to paste
/// instead; null when the region has none.
String? whereStaticWarning(String source, String className) {
  final start = source.indexOf(_staticsStart);
  final end = source.indexOf(_staticsEnd);
  if (start == -1 || end < start) {
    return null;
  }
  final match = _nullForwardingWhere.firstMatch(source.substring(start, end));
  if (match == null || match[0]!.contains('QueryBuilder.absent')) {
    return null;
  }
  return '$className: the where static passes null on for a left-out '
      "argument, so $className.where('a', '<>') and "
      "$className.where('a', '<>', null) look the same. Replace it with:\n"
      '${whereStaticLines(className).join('\n')}';
}

/// Fills an empty statics region of [source] with [staticLines]. A region
/// that holds anything belongs to the application and is left alone, as is
/// a source without the markers: both return [source] unchanged. [lines]
/// replaces [staticLines] (`model:sync` passes them formatted).
String fillStatics(
  String source,
  String className, {
  String? idType,
  List<String>? lines,
}) {
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
      '${(lines ?? staticLines(className, idType: idType)).join('\n')}\n'
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
///
/// With [formatter] (`model:sync` passes the project's), the code written
/// into each region is laid out as `dart format` would, so a synced model
/// stays format-clean; code outside the regions is never touched. A region
/// the formatter cannot parse is written as generated, with a warning.
ModelSync syncModelSource(
  String source,
  ModelSource model,
  List<ColumnInfo> columns, {
  SqlDialect dialect = SqlDialect.sqlite,
  String? idStub,
  RegionFormatter? formatter,
}) {
  final warnings = <String>[?whereStaticWarning(source, model.className)];
  List<String> members(List<String> lines, String region) {
    if (formatter == null) {
      return lines;
    }
    final formatted = formatter.members(lines.join('\n'));
    if (formatter.lastFailure != null) {
      warnings.add(
        'The $region region could not be formatted (${formatter.lastFailure}); '
        'written as generated.',
      );
    }
    return formatted.split('\n');
  }

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
      var ids = renderStub(
        idStub,
        idStubValues(model.className, representation),
      );
      if (formatter != null) {
        ids = formatter.topLevel(ids);
        if (formatter.lastFailure != null) {
          warnings.add(
            'The ids region could not be formatted '
            '(${formatter.lastFailure}); written as generated.',
          );
        }
      }
      next = replaceIds(
        typeStatics(
          fillStatics(
            next,
            model.className,
            idType: idType,
            lines: members(
              staticLines(model.className, idType: idType),
              'statics',
            ),
          ),
          idType,
        ),
        ids,
      );
    }
  }
  if (idType == null) {
    next = fillStatics(
      next,
      model.className,
      lines: members(staticLines(model.className), 'statics'),
    );
  }
  final plan = planAccessors(model, columns, dialect: dialect, idType: idType);
  warnings.insertAll(0, plan.warnings);
  for (final key in unreadRelations(source, model)) {
    warnings.add(
      'Relation [$key] could not be read: model:sync reads '
      "`'$key': () => HasMany<Post>(...)` and the other relation classes "
      'written that way, so it has no rels entry, getter or relation path; '
      "the string '$key' still loads it.",
    );
  }
  final accessors = replaceAccessors(next, members(plan.lines, 'accessors'));
  if (accessors == null) {
    return (source: null, plan: plan, warnings: warnings);
  }
  final paths = relationPathPlan(model, {
    for (final n in columnNames(columns)) ?n.getter,
  });
  warnings.addAll(paths.warnings);
  var code = paths.lines.join('\n');
  if (formatter != null && code.isNotEmpty) {
    code = formatter.topLevel(code);
    if (formatter.lastFailure != null) {
      warnings.add(
        'The relation-path region could not be formatted '
        '(${formatter.lastFailure}); written as generated.',
      );
    }
  }
  return (
    source: replaceRelationPath(accessors, code),
    plan: plan,
    warnings: warnings,
  );
}
