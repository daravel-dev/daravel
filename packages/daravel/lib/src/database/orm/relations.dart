import '../database_manager.dart';
import '../query/query_ast.dart';
import '../query/query_builder.dart';
import 'model.dart';
import 'model_collection.dart';
import 'model_definition.dart';
import 'model_query.dart';
import '../../foundation/clock.dart';

/// Constraint applied to a relation query (`with({'posts': (q) => ...})`).
typedef RelationConstraint = void Function(ModelQuery<Model> query);

/// Constraint for `whereHasMorph`, called once per target [type].
typedef MorphConstraint = void Function(
  ModelQuery<Model> query,
  ModelDefinition<Model> type,
);

/// Base relation (BLUEPRINT_V2 §7.5.4). Related definitions are resolved
/// lazily through a thunk so two models may reference each other.
abstract class Relation<R extends Model> {
  Relation(this._related);

  final ModelDefinition<R> Function() _related;

  /// Name under which the relation is registered (set by the definition).
  String name = '';

  ModelDefinition<R> get related => _related();

  /// Query returning the related models of one [parent].
  ModelQuery<R> queryFor(Model parent, DatabaseManager db);

  /// Loads the relation for many [parents] in one batched query and stores
  /// the result on each parent under [name].
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]);

  /// A query on the related table correlated with the parent table, for
  /// `whereHas` / `withCount`.
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db);

  /// The related rows' columns this relation matches them on (its foreign
  /// or owner key): added back when an eager load selects columns without
  /// them (`with_('user:name')` still reads `users.id`).
  List<String> get matchColumns => const [];

  /// The parent rows' columns this relation reads (its local or foreign
  /// key): added to a parent query that selects columns without them, so
  /// the relation can still be loaded from its rows.
  List<String> get parentColumns => const [];

  /// Adds the [columns] that [query] (on [table]) does not select yet;
  /// bare names are qualified with [table]. A query that selects every
  /// column (none listed, `*`, `table.*`) is left alone.
  static void keepColumns(
    QueryBuilder query,
    String table,
    Iterable<Object> columns,
  ) {
    final selected = query.ast.columns;
    if (selected.isEmpty || selected.any((c) => c == '*' || c == '$table.*')) {
      return;
    }
    final missing = [
      for (final column in columns)
        if (!selected.any(
          (c) => c == column || (column is String && c == '$table.$column'),
        ))
          column is String && _bare.hasMatch(column)
              ? '$table.$column'
              : column,
    ];
    if (missing.isNotEmpty) {
      query.addSelect(missing);
    }
  }

  /// Qualifies the bare column names [query] selects with [table]: a
  /// query joining a pivot or intermediate table would find `id` ambiguous.
  static void qualifySelect(QueryBuilder query, String table) {
    final selected = query.ast.columns;
    for (var i = 0; i < selected.length; i++) {
      final column = selected[i];
      if (column is String && _bare.hasMatch(column)) {
        selected[i] = '$table.$column';
      }
    }
  }

  static final RegExp _bare = RegExp(r'^\w+$');

  /// [correlated] against the parent table as [parentTable] names it (an
  /// alias inside a self-relation subquery). The built-in relations alias
  /// their own table when it has the parent's name (`categories` whose
  /// `children` are `categories`); custom relations fall back to
  /// [correlated].
  ModelQuery<R> existenceQuery(
    ModelDefinition<Model> parent,
    DatabaseManager db, {
    required String parentTable,
  }) => correlated(parent, db);

  static int _selfJoinCount = 0;

  /// The related query for an existence subquery, aliased as Laravel's
  /// `laravel_reserved_N` when its table is the parent's.
  ModelQuery<R> _existenceBase(DatabaseManager db, String parentTable) {
    final query = related.query(db: db);
    if (related.table == parentTable) {
      query.aliasTable('laravel_reserved_${_selfJoinCount++}');
    }
    return query;
  }

  /// The models loaded under [name] on [parents], flattened (for nested
  /// eager loading).
  List<Model> loadedModels(List<Model> parents) => [
    for (final parent in parents)
      if (parent.relationLoaded(name))
        ...switch (parent.relations[name]) {
          final Model m => [m],
          final List<Model> list => list,
          _ => const <Model>[],
        },
  ];

  static List<List<T>> chunk<T>(List<T> items, int size) => [
    for (var i = 0; i < items.length; i += size)
      items.sublist(i, i + size > items.length ? items.length : i + size),
  ];

  // ---------------------------------------------------------------------------
  // Morph map (Laravel's Relation::morphMap)
  // ---------------------------------------------------------------------------

  static final Map<String, ModelDefinition<Model> Function()> _morphMap = {};
  static bool _requireMorphMap = false;

  /// Registers morph aliases: a model listed here is stored in `*_type`
  /// columns under its alias (`'post'`) instead of its
  /// [ModelDefinition.morphClass], and [MorphTo] resolves the alias back.
  /// Returns the current map.
  static Map<String, ModelDefinition<Model> Function()> morphMap([
    Map<String, ModelDefinition<Model> Function()>? map,
    bool merge = true,
  ]) {
    if (map != null) {
      if (!merge) {
        _morphMap.clear();
      }
      _morphMap.addAll(map);
    }
    return Map.unmodifiable(_morphMap);
  }

  /// [morphMap] and [requireMorphMap]: every model used in a polymorphic
  /// relation must then have an alias.
  static void enforceMorphMap(
    Map<String, ModelDefinition<Model> Function()> map, {
    bool merge = true,
  }) {
    requireMorphMap();
    morphMap(map, merge);
  }

  /// Whether models without a morph alias are refused
  /// (`ClassMorphViolationException` in Laravel).
  static void requireMorphMap([bool require = true]) =>
      _requireMorphMap = require;

  static bool get requiresMorphMap => _requireMorphMap;

  /// The value stored in `*_type` columns for [definition] (Laravel's
  /// `getMorphClass`): its morph alias, else its
  /// [ModelDefinition.morphClass].
  static String morphClassOf(ModelDefinition<Model> definition) {
    final alias = _aliasOf(definition);
    if (alias != null) {
      return alias;
    }
    if (_requireMorphMap) {
      throw StateError(
        'No morph map defined for model [${definition.morphClass}].',
      );
    }
    return definition.morphClass;
  }

  /// The definition registered under [alias] (`getMorphedModel`), or null.
  static ModelDefinition<Model>? morphedModel(String alias) =>
      _morphMap[alias]?.call();

  static String? _aliasOf(ModelDefinition<Model> definition) {
    for (final MapEntry(:key, :value) in _morphMap.entries) {
      if (identical(value(), definition)) {
        return key;
      }
    }
    return null;
  }
}

/// `hasMany`: related rows carry `foreignKey` = parent `localKey`.
class HasMany<R extends Model> extends Relation<R> {
  HasMany(super.related, {required this.foreignKey, this.localKey = 'id'});

  final String foreignKey;
  final String localKey;

  @override
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) =>
      related.query(db: db).where(foreignKey, parent.attributes[localKey]);

  @override
  List<String> get matchColumns => [foreignKey];

  @override
  List<String> get parentColumns => [localKey];

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    final keys = {for (final p in parents) p.attributes[localKey]}
      ..remove(null);
    final grouped = <Object?, List<R>>{};
    for (final batch in Relation.chunk(keys.toList(), 500)) {
      final query = related.query(db: db).whereIn(foreignKey, batch);
      constraint?.call(query as ModelQuery<Model>);
      Relation.keepColumns(query.builder, query.tableName, matchColumns);
      for (final model in await query.get()) {
        grouped
            .putIfAbsent(model.attributes[foreignKey], () => <R>[])
            .add(model);
      }
    }
    for (final parent in parents) {
      parent.setRelation(
        name,
        ModelCollection<R>(grouped[parent.attributes[localKey]] ?? <R>[]),
      );
    }
  }

  @override
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db) =>
      existenceQuery(parent, db, parentTable: parent.table);

  @override
  ModelQuery<R> existenceQuery(
    ModelDefinition<Model> parent,
    DatabaseManager db, {
    required String parentTable,
  }) {
    final query = _existenceBase(db, parentTable);
    return query.whereColumn(
      '${query.tableName}.$foreignKey',
      '=',
      '$parentTable.$localKey',
    );
  }

  /// Creates a related model with the foreign key set.
  Future<R> create(
    Model parent,
    DatabaseManager db,
    Map<String, Object?> attributes,
  ) async {
    final model = related.newInstance(attributes, db)
      ..setAttr(foreignKey, parent.attributes[localKey]);
    await model.save();
    return model;
  }
}

/// `hasOne`: like [HasMany] but a single row.
final class HasOne<R extends Model> extends HasMany<R> {
  HasOne(super.related, {required super.foreignKey, super.localKey});

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    await super.eagerLoad(parents, db, constraint);
    for (final parent in parents) {
      final list = parent.relations[name] as List<Model>;
      parent.setRelation(name, list.isEmpty ? null : list.first);
    }
  }
}

/// `belongsTo`: the parent carries `foreignKey` = related `ownerKey`.
final class BelongsTo<R extends Model> extends Relation<R> {
  BelongsTo(super.related, {required this.foreignKey, this.ownerKey = 'id'});

  final String foreignKey;
  final String ownerKey;

  @override
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) =>
      related.query(db: db).where(ownerKey, parent.attributes[foreignKey]);

  @override
  List<String> get matchColumns => [ownerKey];

  @override
  List<String> get parentColumns => [foreignKey];

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    final keys = {for (final p in parents) p.attributes[foreignKey]}
      ..remove(null);
    final byKey = <Object?, R>{};
    for (final batch in Relation.chunk(keys.toList(), 500)) {
      final query = related.query(db: db).whereIn(ownerKey, batch);
      constraint?.call(query as ModelQuery<Model>);
      Relation.keepColumns(query.builder, query.tableName, matchColumns);
      for (final model in await query.get()) {
        byKey[model.attributes[ownerKey]] = model;
      }
    }
    for (final parent in parents) {
      parent.setRelation(name, byKey[parent.attributes[foreignKey]]);
    }
  }

  @override
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db) =>
      existenceQuery(parent, db, parentTable: parent.table);

  @override
  ModelQuery<R> existenceQuery(
    ModelDefinition<Model> parent,
    DatabaseManager db, {
    required String parentTable,
  }) {
    final query = _existenceBase(db, parentTable);
    return query.whereColumn(
      '${query.tableName}.$ownerKey',
      '=',
      '$parentTable.$foreignKey',
    );
  }

  /// Sets the foreign key on [parent] to point at [owner] (no save).
  void associate(Model parent, R owner) =>
      parent.setAttr(foreignKey, owner.attributes[ownerKey]);

  /// Clears the foreign key on [parent] (no save).
  void dissociate(Model parent) => parent.setAttr(foreignKey, null);
}

/// `belongsToMany` through a pivot table.
final class BelongsToMany<R extends Model> extends Relation<R> {
  BelongsToMany(
    super.related, {
    required this.pivotTable,
    required this.foreignPivotKey,
    required this.relatedPivotKey,
    this.parentKey = 'id',
    this.relatedKey = 'id',
    this.withPivot = const <String>[],
    this.withTimestamps = false,
  });

  final String pivotTable;
  final String foreignPivotKey;
  final String relatedPivotKey;
  final String parentKey;
  final String relatedKey;
  final List<String> withPivot;
  final bool withTimestamps;

  List<String> get _pivotColumns => [
    foreignPivotKey,
    relatedPivotKey,
    ...withPivot,
    if (withTimestamps) ...['created_at', 'updated_at'],
  ];

  List<String> get _pivotSelect => [
    for (final column in _pivotColumns) '$pivotTable.$column as pivot_$column',
  ];

  @override
  List<String> get parentColumns => [parentKey];

  ModelQuery<R> _base(DatabaseManager db) {
    final query = related.query(db: db);
    query.builder
      ..join(
        pivotTable,
        '$pivotTable.$relatedPivotKey',
        '=',
        '${related.table}.$relatedKey',
      )
      ..select(['${related.table}.*', ..._pivotSelect]);
    return query;
  }

  // Hooks for the polymorphic pivot relations ([MorphToMany]).

  /// Extra constraints on queries through the pivot table.
  ModelQuery<R> _scoped(ModelQuery<R> query, ModelDefinition<Model> parent) =>
      query;

  /// The pivot rows of [parent].
  QueryBuilder _parentPivot(Model parent, DatabaseManager db) =>
      _pivot(db).where(foreignPivotKey, parent.attributes[parentKey]);

  /// Extra values written to new pivot rows of [parent].
  Map<String, Object?> _pivotValues(Model parent) => const {};

  @override
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) => _scoped(
    _base(db)
        .where('$pivotTable.$foreignPivotKey', parent.attributes[parentKey]),
    parent.modelDefinition,
  );

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    final keys = {for (final p in parents) p.attributes[parentKey]}
      ..remove(null);
    final grouped = <Object?, List<R>>{};
    for (final batch in Relation.chunk(keys.toList(), 500)) {
      final query = _scoped(
        _base(db).whereIn('$pivotTable.$foreignPivotKey', batch),
        parents.first.modelDefinition,
      );
      constraint?.call(query as ModelQuery<Model>);
      // As Laravel's shouldSelect: the pivot columns whatever was selected.
      Relation.qualifySelect(query.builder, related.table);
      Relation.keepColumns(query.builder, related.table, _pivotSelect);
      for (final model in await query.get()) {
        grouped
            .putIfAbsent(model.pivot?[foreignPivotKey], () => <R>[])
            .add(model);
      }
    }
    for (final parent in parents) {
      parent.setRelation(
        name,
        ModelCollection<R>(grouped[parent.attributes[parentKey]] ?? <R>[]),
      );
    }
  }

  @override
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db) =>
      existenceQuery(parent, db, parentTable: parent.table);

  @override
  ModelQuery<R> existenceQuery(
    ModelDefinition<Model> parent,
    DatabaseManager db, {
    required String parentTable,
  }) {
    final query = _existenceBase(db, parentTable);
    query.builder
      ..join(
        pivotTable,
        '$pivotTable.$relatedPivotKey',
        '=',
        '${query.tableName}.$relatedKey',
      )
      ..whereColumn(
        '$pivotTable.$foreignPivotKey',
        '=',
        '$parentTable.$parentKey',
      );
    return _scoped(query, parent);
  }

  QueryBuilder _pivot(DatabaseManager db) =>
      db.table(pivotTable, connection: related.connection);

  static List<Object?> _ids(Object ids) => switch (ids) {
    Model() => [ids.key],
    List<Object?>() => [for (final id in ids) id is Model ? id.key : id],
    _ => [ids],
  };

  Future<void> attach(
    Model parent,
    DatabaseManager db,
    Object ids,
    Map<String, Object?> pivot,
  ) async {
    final now = formatNow();
    final rows = [
      for (final id in _ids(ids))
        {
          foreignPivotKey: parent.attributes[parentKey],
          relatedPivotKey: id,
          ..._pivotValues(parent),
          ...pivot,
          if (withTimestamps) ...{'created_at': now, 'updated_at': now},
        },
    ];
    await _pivot(db).insert(rows);
  }

  Future<int> detach(Model parent, DatabaseManager db, Object? ids) {
    final query = _parentPivot(parent, db);
    if (ids != null) {
      query.whereIn(relatedPivotKey, _ids(ids));
    }
    return query.delete();
  }

  Future<Map<String, List<Object?>>> sync(
    Model parent,
    DatabaseManager db,
    Object ids, {
    bool detaching = true,
  }) async {
    final wanted = _ids(ids);
    final current = (await _parentPivot(
      parent,
      db,
    ).pluck(relatedPivotKey)) as List<Object?>;
    final toAttach = wanted.where((id) => !current.contains(id)).toList();
    final toDetach = detaching
        ? current.where((id) => !wanted.contains(id)).toList()
        : const <Object?>[];
    if (toDetach.isNotEmpty) {
      await detach(parent, db, toDetach);
    }
    if (toAttach.isNotEmpty) {
      await attach(parent, db, toAttach, const {});
    }
    return {'attached': toAttach, 'detached': toDetach, 'updated': const []};
  }

  static String formatNow() {
    final now = Clock.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}

/// `hasManyThrough`: parent → through (`firstKey` = parent `localKey`) →
/// related (`secondKey` = through `secondLocalKey`).
class HasManyThrough<R extends Model> extends Relation<R> {
  HasManyThrough(
    super.related, {
    required this.through,
    required this.firstKey,
    required this.secondKey,
    this.localKey = 'id',
    this.secondLocalKey = 'id',
  });

  final ModelDefinition<Model> Function() through;
  final String firstKey;
  final String secondKey;
  final String localKey;
  final String secondLocalKey;

  static const String throughKeyAlias = 'laravel_through_key';

  @override
  List<String> get parentColumns => [localKey];

  ModelQuery<R> _base(DatabaseManager db) {
    final throughTable = through().table;
    final query = related.query(db: db);
    query.builder
      ..join(
        throughTable,
        '$throughTable.$secondLocalKey',
        '=',
        '${related.table}.$secondKey',
      )
      ..select([
        '${related.table}.*',
        '$throughTable.$firstKey as $throughKeyAlias',
      ]);
    return query;
  }

  @override
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) =>
      _base(db)
          .where('${through().table}.$firstKey', parent.attributes[localKey]);

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    final throughTable = through().table;
    final keys = {for (final p in parents) p.attributes[localKey]}
      ..remove(null);
    final grouped = <Object?, List<R>>{};
    for (final batch in Relation.chunk(keys.toList(), 500)) {
      final query = _base(db).whereIn('$throughTable.$firstKey', batch);
      constraint?.call(query as ModelQuery<Model>);
      Relation.qualifySelect(query.builder, related.table);
      Relation.keepColumns(query.builder, related.table, [
        '$throughTable.$firstKey as $throughKeyAlias',
      ]);
      for (final model in await query.get()) {
        grouped
            .putIfAbsent(model.attributes[throughKeyAlias], () => <R>[])
            .add(model);
      }
    }
    for (final parent in parents) {
      parent.setRelation(
        name,
        ModelCollection<R>(grouped[parent.attributes[localKey]] ?? <R>[]),
      );
    }
  }

  @override
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db) =>
      existenceQuery(parent, db, parentTable: parent.table);

  @override
  ModelQuery<R> existenceQuery(
    ModelDefinition<Model> parent,
    DatabaseManager db, {
    required String parentTable,
  }) {
    final throughTable = through().table;
    final query = _existenceBase(db, parentTable);
    query.builder
      ..join(
        throughTable,
        '$throughTable.$secondLocalKey',
        '=',
        '${query.tableName}.$secondKey',
      )
      ..whereColumn('$throughTable.$firstKey', '=', '$parentTable.$localKey');
    return query;
  }
}

/// `hasOneThrough`: like [HasManyThrough] but a single model (or null).
final class HasOneThrough<R extends Model> extends HasManyThrough<R> {
  HasOneThrough(
    super.related, {
    required super.through,
    required super.firstKey,
    required super.secondKey,
    super.localKey,
    super.secondLocalKey,
  });

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    await super.eagerLoad(parents, db, constraint);
    for (final parent in parents) {
      final list = parent.relations[name] as List<Model>;
      parent.setRelation(name, list.isEmpty ? null : list.first);
    }
  }
}

// -----------------------------------------------------------------------------
// Polymorphic relations
// -----------------------------------------------------------------------------

/// `morphMany`: related rows carry `{morphName}_type` = the parent's morph
/// class ([Relation.morphClassOf]) and `{morphName}_id` = the parent's
/// [localKey], so posts and videos can share one `comments` table.
class MorphMany<R extends Model> extends HasMany<R> {
  MorphMany(
    super.related, {
    required this.morphName,
    String? morphType,
    String? foreignKey,
    super.localKey,
  }) : morphType = morphType ?? '${morphName}_type',
       super(foreignKey: foreignKey ?? '${morphName}_id');

  final String morphName;

  /// The column holding the parent's morph class.
  final String morphType;

  @override
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) => super
      .queryFor(parent, db)
      .where(morphType, Relation.morphClassOf(parent.modelDefinition));

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) {
    if (parents.isEmpty) {
      return Future.value();
    }
    // The parents of one eager load share a definition (see loadRelationsOn).
    final type = Relation.morphClassOf(parents.first.modelDefinition);
    return super.eagerLoad(parents, db, (query) {
      query.where(morphType, type);
      constraint?.call(query);
    });
  }

  @override
  ModelQuery<R> existenceQuery(
    ModelDefinition<Model> parent,
    DatabaseManager db, {
    required String parentTable,
  }) {
    final query = super.existenceQuery(parent, db, parentTable: parentTable);
    return query.where(
      '${query.tableName}.$morphType',
      Relation.morphClassOf(parent),
    );
  }

  /// Creates a related model with the morph type and id set.
  @override
  Future<R> create(
    Model parent,
    DatabaseManager db,
    Map<String, Object?> attributes,
  ) async {
    final model = related.newInstance(attributes, db)
      ..setAttr(foreignKey, parent.attributes[localKey])
      ..setAttr(morphType, Relation.morphClassOf(parent.modelDefinition));
    await model.save();
    return model;
  }
}

/// `morphOne`: like [MorphMany] but a single row.
final class MorphOne<R extends Model> extends MorphMany<R> {
  MorphOne(
    super.related, {
    required super.morphName,
    super.morphType,
    super.foreignKey,
    super.localKey,
  });

  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    await super.eagerLoad(parents, db, constraint);
    for (final parent in parents) {
      final list = parent.relations[name] as List<Model>;
      parent.setRelation(name, list.isEmpty ? null : list.first);
    }
  }
}

/// `morphTo`: the inverse of [MorphOne] / [MorphMany]. Each row names its
/// owner's type in [morphType] and key in [foreignKey], so rows of one
/// table may point at different models (a comment on a post or a video).
///
/// [morphName] defaults to the name the relation is registered under, as
/// Laravel defaults it to the method name. Stored types are resolved
/// through [types] and then [Relation.morphMap]: there is no reflection to
/// turn `App\Models\Post` into a model, so every possible target must be
/// listed in one of the two.
final class MorphTo extends Relation<Model> {
  MorphTo({
    this._morphName,
    this._morphType,
    this._foreignKey,
    this.ownerKey,
    this.types = const [],
  }) : super(_noSingleRelated);

  final String? _morphName;
  final String? _morphType;
  final String? _foreignKey;

  /// The key of the target models (their primary key when null).
  final String? ownerKey;

  /// The models this relation may point at (besides [Relation.morphMap]).
  final List<ModelDefinition<Model> Function()> types;

  String get morphName => _morphName ?? name;

  /// The column holding the owner's morph class (`{morphName}_type`).
  String get morphType => _morphType ?? '${morphName}_type';

  /// The column holding the owner's key (`{morphName}_id`).
  String get foreignKey => _foreignKey ?? '${morphName}_id';

  static ModelDefinition<Model> _noSingleRelated() => throw StateError(
    'A MorphTo relation has no single related model; its rows point at '
    'different models.',
  );

  /// Every model this relation may point at: [types], then the morph map.
  List<ModelDefinition<Model>> get knownTypes {
    final known = <ModelDefinition<Model>>[];
    for (final type in [...types, ...Relation._morphMap.values]) {
      final definition = type();
      if (!known.any((d) => identical(d, definition))) {
        known.add(definition);
      }
    }
    return known;
  }

  /// The model stored as [type] in [morphType]: its alias or, as Laravel
  /// still resolves rows written before an alias existed, its class name.
  ModelDefinition<Model> definitionFor(String type) {
    final mapped = Relation.morphedModel(type);
    if (mapped != null) {
      return mapped;
    }
    for (final definition in knownTypes) {
      if (definition.morphClass == type ||
          Relation._aliasOf(definition) == type) {
        return definition;
      }
    }
    throw StateError(
      'Cannot resolve the morph type [$type] of relation [$morphName]: '
      'list its model in MorphTo(types: [...]) or register it with '
      'Relation.morphMap().',
    );
  }

  String _keyOf(ModelDefinition<Model> definition) =>
      ownerKey ?? definition.primaryKey;

  @override
  List<String> get parentColumns => [morphType, foreignKey];

  @override
  ModelQuery<Model> queryFor(Model parent, DatabaseManager db) {
    final type = parent.attributes[morphType];
    if (type == null) {
      throw StateError(
        '[${parent.table}.$morphType] is null: relation [$morphName] points '
        'at nothing.',
      );
    }
    final definition = definitionFor('$type');
    return definition
        .query(db: db)
        .where(_keyOf(definition), parent.attributes[foreignKey]);
  }

  /// One query per stored type, as Laravel's `MorphTo` eager loads.
  @override
  Future<void> eagerLoad(
    List<Model> parents,
    DatabaseManager db, [
    RelationConstraint? constraint,
  ]) async {
    final byType = <String, List<Model>>{};
    for (final parent in parents) {
      final type = parent.attributes[morphType];
      if (type == null || parent.attributes[foreignKey] == null) {
        parent.setRelation(name, null);
        continue;
      }
      byType.putIfAbsent('$type', () => []).add(parent);
    }
    for (final MapEntry(key: type, value: group) in byType.entries) {
      final definition = definitionFor(type);
      final key = _keyOf(definition);
      final ids = {for (final p in group) p.attributes[foreignKey]}.toList();
      // Keys compare as strings, as Laravel's dictionary keys do.
      final byKey = <String, Model>{};
      for (final batch in Relation.chunk(ids, 500)) {
        final query = definition.query(db: db).whereIn(key, batch);
        constraint?.call(query);
        Relation.keepColumns(query.builder, query.tableName, [key]);
        for (final model in await query.get()) {
          byKey['${model.attributes[key]}'] = model;
        }
      }
      for (final parent in group) {
        parent.setRelation(name, byKey['${parent.attributes[foreignKey]}']);
      }
    }
  }

  /// Not available: the owner table depends on each row. `whereHas` on a
  /// `MorphTo` goes through `whereHasMorph` instead.
  @override
  ModelQuery<Model> correlated(
    ModelDefinition<Model> parent,
    DatabaseManager db,
  ) => throw UnsupportedError(
    'Relation [$morphName] is a MorphTo: query it with whereHasMorph().',
  );

  /// A query on [type] correlated with the parent table (named
  /// [parentTable]), for `whereHasMorph`.
  ModelQuery<Model> correlatedTo(
    ModelDefinition<Model> type,
    DatabaseManager db, {
    required String parentTable,
  }) {
    final query = type.query(db: db);
    if (type.table == parentTable) {
      query.aliasTable('laravel_reserved_${Relation._selfJoinCount++}');
    }
    return query.whereColumn(
      '${query.tableName}.${_keyOf(type)}',
      '=',
      '$parentTable.$foreignKey',
    );
  }

  /// Points [child] at [owner] (no save).
  void associate(Model child, Model owner) => child
    ..setAttr(morphType, Relation.morphClassOf(owner.modelDefinition))
    ..setAttr(foreignKey, owner.attributes[_keyOf(owner.modelDefinition)])
    ..setRelation(name, owner);

  /// Clears the morph columns of [child] (no save).
  void dissociate(Model child) => child
    ..setAttr(morphType, null)
    ..setAttr(foreignKey, null)
    ..setRelation(name, null);
}

/// `morphToMany`: a polymorphic many-to-many through a pivot table holding
/// `{morphName}_type`, `{morphName}_id` and [relatedPivotKey] (`taggables`:
/// the tags of posts and of videos). [pivotTable] defaults to
/// `{morphName}s`; pass it when the plural is irregular.
final class MorphToMany<R extends Model> extends BelongsToMany<R> {
  MorphToMany(
    super.related, {
    required this.morphName,
    required super.relatedPivotKey,
    String? pivotTable,
    String? foreignPivotKey,
    String? morphType,
    super.parentKey,
    super.relatedKey,
    super.withPivot,
    super.withTimestamps,
  }) : morphType = morphType ?? '${morphName}_type',
       _inverse = false,
       super(
         pivotTable: pivotTable ?? '${morphName}s',
         foreignPivotKey: foreignPivotKey ?? '${morphName}_id',
       );

  MorphToMany._inverse(
    super.related, {
    required this.morphName,
    required super.foreignPivotKey,
    String? pivotTable,
    String? relatedPivotKey,
    String? morphType,
    super.parentKey,
    super.relatedKey,
    super.withPivot,
    super.withTimestamps,
  }) : morphType = morphType ?? '${morphName}_type',
       _inverse = true,
       super(
         pivotTable: pivotTable ?? '${morphName}s',
         relatedPivotKey: relatedPivotKey ?? '${morphName}_id',
       );

  final String morphName;

  /// The pivot column holding the morph class.
  final String morphType;

  /// [MorphedByMany]: the morph type is the related model's.
  final bool _inverse;

  String _typeFor(ModelDefinition<Model> parent) =>
      Relation.morphClassOf(_inverse ? related : parent);

  @override
  ModelQuery<R> _scoped(ModelQuery<R> query, ModelDefinition<Model> parent) =>
      query.where('$pivotTable.$morphType', _typeFor(parent));

  @override
  QueryBuilder _parentPivot(Model parent, DatabaseManager db) => super
      ._parentPivot(parent, db)
      .where(morphType, _typeFor(parent.modelDefinition));

  @override
  Map<String, Object?> _pivotValues(Model parent) => {
    morphType: _typeFor(parent.modelDefinition),
  };
}

/// `morphedByMany`: the inverse of [MorphToMany] (the posts of a tag). The
/// pivot's `{morphName}_type` is the related model's morph class.
final class MorphedByMany<R extends Model> extends MorphToMany<R> {
  MorphedByMany(
    super.related, {
    required super.morphName,
    required super.foreignPivotKey,
    super.pivotTable,
    super.relatedPivotKey,
    super.morphType,
    super.parentKey,
    super.relatedKey,
    super.withPivot,
    super.withTimestamps,
  }) : super._inverse();
}

/// Raw helper re-exported for relation subqueries.
typedef Raw = RawExpression;
