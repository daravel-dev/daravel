import '../database_manager.dart';
import '../query/query_ast.dart';
import '../query/query_builder.dart';
import 'model.dart';
import 'model_collection.dart';
import 'model_definition.dart';
import 'model_query.dart';

/// Constraint applied to a relation query (`with({'posts': (q) => ...})`).
typedef RelationConstraint = void Function(ModelQuery<Model> query);

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
      related
          .query(db: db)
          .whereColumn(
            '${related.table}.$foreignKey',
            '=',
            '${parent.table}.$localKey',
          );

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
      related
          .query(db: db)
          .whereColumn(
            '${related.table}.$ownerKey',
            '=',
            '${parent.table}.$foreignKey',
          );

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

  ModelQuery<R> _base(DatabaseManager db) {
    final query = related.query(db: db);
    query.builder
      ..join(
        pivotTable,
        '$pivotTable.$relatedPivotKey',
        '=',
        '${related.table}.$relatedKey',
      )
      ..select([
        '${related.table}.*',
        for (final column in _pivotColumns)
          '$pivotTable.$column as pivot_$column',
      ]);
    return query;
  }

  @override
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) => _base(
    db,
  ).where('$pivotTable.$foreignPivotKey', parent.attributes[parentKey]);

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
      final query = _base(db).whereIn('$pivotTable.$foreignPivotKey', batch);
      constraint?.call(query as ModelQuery<Model>);
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
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db) {
    final query = related.query(db: db);
    query.builder
      ..join(
        pivotTable,
        '$pivotTable.$relatedPivotKey',
        '=',
        '${related.table}.$relatedKey',
      )
      ..whereColumn(
        '$pivotTable.$foreignPivotKey',
        '=',
        '${parent.table}.$parentKey',
      );
    return query;
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
          ...pivot,
          if (withTimestamps) ...{'created_at': now, 'updated_at': now},
        },
    ];
    await _pivot(db).insert(rows);
  }

  Future<int> detach(Model parent, DatabaseManager db, Object? ids) {
    final query = _pivot(
      db,
    ).where(foreignPivotKey, parent.attributes[parentKey]);
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
    final current =
        (await _pivot(db)
                .where(foreignPivotKey, parent.attributes[parentKey])
                .pluck(relatedPivotKey))
            as List<Object?>;
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
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}

/// `hasManyThrough`: parent → through (`firstKey` = parent `localKey`) →
/// related (`secondKey` = through `secondLocalKey`).
final class HasManyThrough<R extends Model> extends Relation<R> {
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
  ModelQuery<R> queryFor(Model parent, DatabaseManager db) => _base(
    db,
  ).where('${through().table}.$firstKey', parent.attributes[localKey]);

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
  ModelQuery<R> correlated(ModelDefinition<Model> parent, DatabaseManager db) {
    final throughTable = through().table;
    final query = related.query(db: db);
    query.builder
      ..join(
        throughTable,
        '$throughTable.$secondLocalKey',
        '=',
        '${related.table}.$secondKey',
      )
      ..whereColumn(
        '$throughTable.$firstKey',
        '=',
        '${parent.table}.$localKey',
      );
    return query;
  }
}

/// Raw helper re-exported for relation subqueries.
typedef Raw = RawExpression;
