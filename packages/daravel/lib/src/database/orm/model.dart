import 'dart:async';

import 'package:collection/collection.dart';

import '../../foundation/container.dart';
import '../../http/request.dart';
import '../../http/response.dart';
import '../database_manager.dart';
import '../query/query_ast.dart';
import 'keys.dart';
import 'model_collection.dart';
import 'model_definition.dart';
import 'model_query.dart';
import 'observer.dart';
import 'relations.dart';

/// Thrown when mass assigning a guarded attribute while
/// [Model.preventSilentlyDiscardingAttributes] is enabled.
final class MassAssignmentException implements Exception {
  const MassAssignmentException(this.attribute, this.table);
  final String attribute;
  final String table;
  @override
  String toString() =>
      'MassAssignmentException: [$attribute] is not fillable on [$table]. '
      'Add it to fillable or use forceFill().';
}

/// Thrown by `findOrFail()` and friends.
final class ModelNotFoundException extends RecordNotFound {
  ModelNotFoundException(this.table, this.id)
    : super('No query results for model [$table] with id [$id].');
  final String table;
  final Object? id;
}

/// Base for Hybrid Active Record models (ADR-006): an attribute bag with
/// typed accessors written by the developer (or `dartisan make:model`),
/// dirty tracking, casts, timestamps, soft deletes, relations and events.
///
/// ```dart
/// final class User extends Model {
///   static final modelDefinition = ModelDefinition<User>(table: 'users', factory: User.new, ...);
///   @override
///   ModelDefinition<User> get modelDefinition => User.modelDefinition;
///   static ModelQuery<User> query() => modelDefinition.query();
///   int get id => getAttr('id');
///   String get name => getAttr('name');
///   set name(String value) => setAttr('name', value);
/// }
/// ```
abstract base class Model implements JsonSerializable, Responsable {
  Model();

  /// When true, assigning a guarded attribute throws instead of being
  /// silently dropped (recommended outside production).
  static bool preventSilentlyDiscardingAttributes = false;

  /// When true, accessing a relation that was not eager loaded throws
  /// instead of querying lazily (catches N+1 problems in tests).
  static bool preventLazyLoading = false;

  /// Static metadata; override as `ModelDefinition<User> get modelDefinition`.
  ModelDefinition<Model> get modelDefinition;

  Map<String, Object?> _attributes = <String, Object?>{};
  Map<String, Object?> _original = <String, Object?>{};
  final Map<String, Object?> _relations = <String, Object?>{};
  final Set<String> _hiddenExtra = <String>{};
  final Set<String> _visibleExtra = <String>{};
  final Set<String> _appendsExtra = <String>{};
  DatabaseManager? _db;
  bool _eventsEnabled = true;

  /// Whether the model is persisted.
  bool exists = false;

  /// Whether the model was inserted during the current request/operation.
  bool wasRecentlyCreated = false;

  /// Pivot columns when loaded through a `BelongsToMany` relation.
  Map<String, Object?>? pivot;

  // ---------------------------------------------------------------------------
  // Attributes
  // ---------------------------------------------------------------------------

  /// Raw stored attributes (after `set` casts).
  Map<String, Object?> get attributes => Map.unmodifiable(_attributes);

  /// Attributes as last synced with the database.
  Map<String, Object?> get original => Map.unmodifiable(_original);

  /// Loaded relations by name.
  Map<String, Object?> get relations => Map.unmodifiable(_relations);

  /// Primary key value.
  Object? get key => _attributes[modelDefinition.primaryKey];

  String get table => modelDefinition.table;

  /// The database manager this model was loaded through (or the container's).
  DatabaseManager get database =>
      _db ?? Container.current.make<DatabaseManager>();

  /// Attaches a database manager (used by queries and tests).
  void attachDatabase(DatabaseManager? db) => _db = db;

  /// Replaces every attribute from a database row. Called by the query.
  void hydrateFrom(Map<String, Object?> row, {DatabaseManager? db}) {
    _attributes = Map<String, Object?>.of(row);
    _original = Map<String, Object?>.of(row);
    exists = true;
    _db = db;
    final pivotColumns = <String, Object?>{};
    for (final key in row.keys.where((k) => k.startsWith('pivot_')).toList()) {
      pivotColumns[key.substring(6)] = _attributes.remove(key);
      _original.remove(key);
    }
    if (pivotColumns.isNotEmpty) {
      pivot = pivotColumns;
    }
  }

  /// Typed attribute read with casts and accessors applied.
  R getAttr<R>(String key) {
    final accessor = modelDefinition.accessors[key];
    if (accessor != null) {
      return accessor(this) as R;
    }
    final raw = _attributes[key];
    final cast = modelDefinition.casts[key];
    return (cast == null ? raw : cast.get(raw)) as R;
  }

  /// Attribute write with mutators and casts applied.
  void setAttr(String key, Object? value) {
    final mutator = modelDefinition.mutators[key];
    final mutated = mutator == null ? value : mutator(this, value);
    final cast = modelDefinition.casts[key];
    _attributes[key] = cast == null ? mutated : cast.set(mutated);
  }

  Object? operator [](String key) => getAttr<Object?>(key);

  void operator []=(String key, Object? value) => setAttr(key, value);

  /// Whether [key] has a value in the attribute bag.
  bool hasAttribute(String key) => _attributes.containsKey(key);

  /// Mass assigns [attributes] honouring `fillable`/`guarded`.
  Model fill(Map<String, Object?> attributes) {
    for (final entry in attributes.entries) {
      if (modelDefinition.isFillable(entry.key)) {
        setAttr(entry.key, entry.value);
      } else if (preventSilentlyDiscardingAttributes ||
          modelDefinition.totallyGuarded) {
        throw MassAssignmentException(entry.key, table);
      }
    }
    return this;
  }

  /// Mass assigns [attributes] ignoring `fillable`/`guarded`.
  Model forceFill(Map<String, Object?> attributes) {
    attributes.forEach(setAttr);
    return this;
  }

  /// Whether [key] (or any attribute) differs from the database.
  bool isDirty([String? key]) {
    if (key != null) {
      return !const DeepCollectionEquality().equals(
            _attributes[key],
            _original[key],
          ) ||
          (_attributes.containsKey(key) != _original.containsKey(key));
    }
    return getDirty().isNotEmpty;
  }

  bool isClean([String? key]) => !isDirty(key);

  /// Attributes that changed since the last sync.
  Map<String, Object?> getDirty() => {
    for (final entry in _attributes.entries)
      if (!_original.containsKey(entry.key) ||
          !const DeepCollectionEquality().equals(
            entry.value,
            _original[entry.key],
          ))
        entry.key: entry.value,
  };

  Map<String, Object?> _changes = const {};

  /// Attributes changed by the last `save()`.
  bool wasChanged([String? key]) =>
      key == null ? _changes.isNotEmpty : _changes.containsKey(key);

  /// Marks the current attributes as the persisted state.
  void syncOriginal() => _original = Map<String, Object?>.of(_attributes);

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  ModelQuery<Model> _query() => modelDefinition.query(db: _db);

  /// Inserts or updates the model. Returns `false` when an observer cancels.
  Future<bool> save() async {
    if (!await _fire(ModelEvent.saving)) {
      return false;
    }
    if (exists) {
      final dirty = getDirty();
      if (dirty.isEmpty) {
        _changes = const {};
        return _fire(ModelEvent.saved);
      }
      if (!await _fire(ModelEvent.updating)) {
        return false;
      }
      if (modelDefinition.timestamps && !isDirty(modelDefinition.updatedAt)) {
        setAttr(modelDefinition.updatedAt, _now());
      }
      final changes = getDirty();
      await _query().whereKey(key).builder.update(changes);
      _changes = changes;
      syncOriginal();
      await _fire(ModelEvent.updated);
    } else {
      if (!await _fire(ModelEvent.creating)) {
        return false;
      }
      if (modelDefinition.timestamps) {
        final now = _now();
        if (!_attributes.containsKey(modelDefinition.createdAt) ||
            _attributes[modelDefinition.createdAt] == null) {
          setAttr(modelDefinition.createdAt, now);
        }
        if (!_attributes.containsKey(modelDefinition.updatedAt) ||
            _attributes[modelDefinition.updatedAt] == null) {
          setAttr(modelDefinition.updatedAt, now);
        }
      }
      if (key == null) {
        switch (modelDefinition.keyType) {
          case KeyType.uuid:
            _attributes[modelDefinition.primaryKey] = KeyGenerator.uuid();
          case KeyType.ulid:
            _attributes[modelDefinition.primaryKey] = KeyGenerator.ulid();
          case KeyType.autoInt:
          case KeyType.string:
            break;
        }
      }
      final values = Map<String, Object?>.of(_attributes);
      if (modelDefinition.keyType == KeyType.autoInt) {
        final id = await _query().builder.insertGetId(
          values,
          idColumn: modelDefinition.primaryKey,
        );
        if (id != null) {
          _attributes[modelDefinition.primaryKey] = id;
        }
      } else {
        await _query().builder.insert(values);
      }
      exists = true;
      wasRecentlyCreated = true;
      _changes = Map<String, Object?>.of(_attributes);
      syncOriginal();
      await _fire(ModelEvent.created);
    }
    await _touchOwners();
    return _fire(ModelEvent.saved);
  }

  /// Saves without firing events.
  Future<bool> saveQuietly() => withoutEvents(save);

  /// Mass assigns and saves.
  Future<bool> update(Map<String, Object?> attributes) {
    fill(attributes);
    return save();
  }

  /// Deletes (soft deletes when configured).
  Future<bool> delete() async {
    if (!exists) {
      return false;
    }
    if (!await _fire(ModelEvent.deleting)) {
      return false;
    }
    if (modelDefinition.softDeletes) {
      setAttr(modelDefinition.deletedAt, _now());
      if (modelDefinition.timestamps) {
        setAttr(modelDefinition.updatedAt, _now());
      }
      await _query().withTrashed().whereKey(key).builder.update({
        modelDefinition.deletedAt: _attributes[modelDefinition.deletedAt],
        if (modelDefinition.timestamps)
          modelDefinition.updatedAt: _attributes[modelDefinition.updatedAt],
      });
      syncOriginal();
    } else {
      await _query().whereKey(key).builder.delete();
      exists = false;
    }
    await _fire(ModelEvent.deleted);
    return true;
  }

  /// Permanently deletes a soft-deletable model.
  Future<bool> forceDelete() async {
    if (!exists) {
      return false;
    }
    if (!await _fire(ModelEvent.forceDeleting)) {
      return false;
    }
    await _query().withTrashed().whereKey(key).builder.delete();
    exists = false;
    await _fire(ModelEvent.forceDeleted);
    return true;
  }

  /// Restores a soft-deleted model.
  Future<bool> restore() async {
    if (!modelDefinition.softDeletes) {
      throw StateError('Model [$table] does not use soft deletes.');
    }
    if (!await _fire(ModelEvent.restoring)) {
      return false;
    }
    setAttr(modelDefinition.deletedAt, null);
    final saved = await save();
    await _fire(ModelEvent.restored);
    return saved;
  }

  /// Whether the model is soft deleted.
  bool get trashed =>
      modelDefinition.softDeletes &&
      _attributes[modelDefinition.deletedAt] != null;

  /// Reloads attributes (and drops loaded relations) from the database.
  Future<Model> refresh() async {
    final fresh = await _query().withTrashed().whereKey(key).first();
    if (fresh == null) {
      throw ModelNotFoundException(table, key);
    }
    _attributes = Map<String, Object?>.of(fresh._attributes);
    syncOriginal();
    _relations.clear();
    return this;
  }

  /// A fresh copy from the database (or `null` when gone).
  Future<Model?> fresh() => _query().withTrashed().whereKey(key).first();

  /// Updates the `updated_at` timestamp.
  Future<bool> touch() async {
    if (!modelDefinition.timestamps) {
      return false;
    }
    setAttr(modelDefinition.updatedAt, _now());
    return save();
  }

  /// Atomically increments [column] in the database and locally.
  Future<int> increment(
    String column, [
    num amount = 1,
    Map<String, Object?> extra = const {},
  ]) async {
    final affected = await _query().whereKey(key).builder.increment(
      column,
      amount,
      {
        ...extra,
        if (modelDefinition.timestamps) modelDefinition.updatedAt: _now(),
      },
    );
    final current = getAttr<num?>(column) ?? 0;
    _attributes[column] = current + amount;
    extra.forEach(setAttr);
    syncOriginal();
    return affected;
  }

  Future<int> decrement(
    String column, [
    num amount = 1,
    Map<String, Object?> extra = const {},
  ]) => increment(column, -amount, extra);

  /// Copy without key and timestamps (Laravel `replicate`).
  Model replicate({List<String> except = const []}) {
    final copy = modelDefinition.factory()..attachDatabase(_db);
    final skip = {
      modelDefinition.primaryKey,
      modelDefinition.createdAt,
      modelDefinition.updatedAt,
      modelDefinition.deletedAt,
      ...except,
    };
    for (final entry in _attributes.entries) {
      if (!skip.contains(entry.key)) {
        copy._attributes[entry.key] = entry.value;
      }
    }
    return copy;
  }

  /// Whether [other] is the same row.
  bool isSameAs(Model other) =>
      other.table == table && other.key != null && other.key == key;

  bool isNot(Model other) => !isSameAs(other);

  Future<void> _touchOwners() async {
    for (final name in modelDefinition.touches) {
      final relation = modelDefinition.relation(name);
      if (relation is BelongsTo<Model>) {
        final owner = await relation.queryFor(this, database).first();
        await owner?.touch();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Relations
  // ---------------------------------------------------------------------------

  /// Whether [name] was loaded.
  bool relationLoaded(String name) => _relations.containsKey(name);

  /// Stores a loaded relation result.
  void setRelation(String name, Object? value) => _relations[name] = value;

  /// A loaded relation (`List<Post>` / `ModelCollection<Post>` for *-many,
  /// the model or `null` for *-one). Throws when not loaded and
  /// [preventLazyLoading] is on.
  R related<R>(String name) {
    if (!_relations.containsKey(name)) {
      if (preventLazyLoading) {
        throw StateError(
          'Relation [$name] on [$table] was not eager loaded (preventLazyLoading).',
        );
      }
      throw StateError(
        'Relation [$name] on [$table] is not loaded; call load([\'$name\']) or with([...]).',
      );
    }
    return _relations[name] as R;
  }

  /// A query scoped to the relation [name] (`user.relatedQuery<Post>('posts')`).
  ModelQuery<R> relatedQuery<R extends Model>(String name) {
    final relation = modelDefinition.requireRelation(name);
    return relation.queryFor(this, database) as ModelQuery<R>;
  }

  /// Loads [relations] (list or map with constraints) onto this model.
  Future<Model> load(Object relations) async {
    await modelDefinition.eagerLoad([this], relations, db: _db);
    return this;
  }

  /// Loads the relations that are not loaded yet.
  Future<Model> loadMissing(List<String> relations) async {
    final missing = relations
        .where((r) => !relationLoaded(r.split('.').first))
        .toList();
    if (missing.isNotEmpty) {
      await modelDefinition.eagerLoad([this], missing, db: _db);
    }
    return this;
  }

  /// Attaches [related] through a `BelongsToMany` relation [name].
  Future<void> attach(
    String name,
    Object ids, {
    Map<String, Object?> pivot = const {},
  }) {
    final relation = modelDefinition.requireRelation(name);
    if (relation is! BelongsToMany<Model>) {
      throw StateError('Relation [$name] is not BelongsToMany.');
    }
    return relation.attach(this, database, ids, pivot);
  }

  /// Detaches [ids] (or all) through a `BelongsToMany` relation [name].
  Future<int> detach(String name, [Object? ids]) {
    final relation = modelDefinition.requireRelation(name);
    if (relation is! BelongsToMany<Model>) {
      throw StateError('Relation [$name] is not BelongsToMany.');
    }
    return relation.detach(this, database, ids);
  }

  /// Syncs pivot rows through a `BelongsToMany` relation [name].
  Future<Map<String, List<Object?>>> sync(
    String name,
    Object ids, {
    bool detaching = true,
  }) {
    final relation = modelDefinition.requireRelation(name);
    if (relation is! BelongsToMany<Model>) {
      throw StateError('Relation [$name] is not BelongsToMany.');
    }
    return relation.sync(this, database, ids, detaching: detaching);
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  Future<bool> _fire(ModelEvent event) async {
    if (!_eventsEnabled) {
      return true;
    }
    for (final observer in modelDefinition.observers) {
      final result = await observer.handle(event, this);
      if (result == false) {
        return false;
      }
    }
    return true;
  }

  /// Fires [event] (used by queries for `retrieved`).
  Future<bool> fireEvent(ModelEvent event) => _fire(event);

  /// Runs [body] with model events disabled.
  Future<R> withoutEvents<R>(Future<R> Function() body) async {
    final previous = _eventsEnabled;
    _eventsEnabled = false;
    try {
      return await body();
    } finally {
      _eventsEnabled = previous;
    }
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Model makeHidden(List<String> attributes) {
    _hiddenExtra.addAll(attributes);
    _visibleExtra.removeAll(attributes);
    return this;
  }

  Model makeVisible(List<String> attributes) {
    _visibleExtra.addAll(attributes);
    _hiddenExtra.removeAll(attributes);
    return this;
  }

  Model append(List<String> attributes) {
    _appendsExtra.addAll(attributes);
    return this;
  }

  /// Attributes with casts applied (no hidden filtering).
  Map<String, Object?> toMap() => {
    for (final key in _attributes.keys) key: getAttr<Object?>(key),
  };

  /// JSON representation: visible attributes, appends and loaded relations
  /// (relation names snake_cased as given).
  @override
  Map<String, Object?> toJson() {
    final result = <String, Object?>{};
    final visible = {...modelDefinition.visible, ..._visibleExtra};
    final hidden = {...modelDefinition.hidden, ..._hiddenExtra}
      ..removeAll(_visibleExtra);
    bool show(String key) =>
        (visible.isEmpty || visible.contains(key)) && !hidden.contains(key);

    for (final key in _attributes.keys) {
      if (show(key)) {
        result[key] = _serialize(getAttr<Object?>(key));
      }
    }
    for (final key in {...modelDefinition.appends, ..._appendsExtra}) {
      if (show(key)) {
        result[key] = _serialize(getAttr<Object?>(key));
      }
    }
    for (final entry in _relations.entries) {
      if (show(entry.key)) {
        result[entry.key] = _serialize(entry.value);
      }
    }
    if (pivot != null && show('pivot')) {
      result['pivot'] = pivot;
    }
    return result;
  }

  static Object? _serialize(Object? value) => switch (value) {
    Model() => value.toJson(),
    List<Model>() => [for (final m in value) m.toJson()],
    DateTime() => value.toUtc().toIso8601String(),
    Enum() => value.name,
    RawExpression() => value.sql,
    _ => value,
  };

  @override
  Response toResponse(Request request) => Response.json(toJson());

  @override
  String toString() => '$runtimeType(${modelDefinition.primaryKey}: $key)';

  static DateTime _now() => DateTime.now().toUtc();
}

/// Base for "not found" model errors (kept separate from HTTP so it can be
/// mapped by the exception handler).
class RecordNotFound implements Exception {
  const RecordNotFound(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Convenience alias used by generated code.
typedef Models<T extends Model> = ModelCollection<T>;
