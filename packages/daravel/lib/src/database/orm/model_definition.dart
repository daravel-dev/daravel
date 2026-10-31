import '../database_manager.dart';
import 'casts.dart';
import 'keys.dart';
import 'model.dart';
import 'model_query.dart';
import 'observer.dart';
import 'relations.dart';

/// Local scope: `scopes: {'published': (q, args) => q.where('published', true)}`.
typedef ScopeFn<T extends Model> = void Function(
  ModelQuery<T> query,
  List<Object?> args,
);

/// Global scope applied to every query unless `withoutGlobalScopes()`.
typedef GlobalScopeFn<T extends Model> = void Function(ModelQuery<T> query);

/// Computed attribute: `accessors: {'full_name': (u) => '${u.first} ${u.last}'}`.
typedef AccessorFn<T extends Model> = Object? Function(T model);

/// Attribute mutator: `mutators: {'email': (u, v) => '$v'.toLowerCase()}`.
typedef MutatorFn<T extends Model> = Object? Function(T model, Object? value);

/// Lazily builds a relation (lazy so definitions may reference each other).
typedef RelationFactory = Relation<Model> Function();

/// Static metadata of a model (ADR-006). Declared once per model class with
/// an explicit type (so mutually referencing models do not create an
/// inference cycle):
///
/// ```dart
/// static final ModelDefinition<User> definition = ModelDefinition<User>(
///   table: 'users',
///   factory: User.new,
///   fillable: ['name', 'email', 'password'],
///   hidden: ['password'],
///   casts: {'email_verified_at': Cast.dateTime},
///   relations: {'posts': () => HasMany<Post>(() => Post.definition, foreignKey: 'user_id')},
/// );
/// ```
///
/// Callbacks typed on [T] are wrapped into `Model`-typed functions at
/// construction time, because Dart function parameters are contravariant and
/// a `Map<String, Fn(User)>` cannot be read through `ModelDefinition<Model>`.
final class ModelDefinition<T extends Model> {
  ModelDefinition({
    required this.table,
    required this.factory,
    this.primaryKey = 'id',
    this.keyType = .autoInt,
    this.connection,
    this.fillable = const <String>[],
    this.guarded = const <String>['*'],
    this.casts = const <String, Cast>{},
    this.hidden = const <String>[],
    this.visible = const <String>[],
    this.appends = const <String>[],
    this.timestamps = true,
    this.createdAt = 'created_at',
    this.updatedAt = 'updated_at',
    this.softDeletes = false,
    this.deletedAt = 'deleted_at',
    Map<String, RelationFactory> relations = const <String, RelationFactory>{},
    Map<String, ScopeFn<T>> scopes = const {},
    List<GlobalScopeFn<T>> globalScopes = const [],
    Map<String, AccessorFn<T>> accessors = const {},
    Map<String, MutatorFn<T>> mutators = const {},
    this.observers = const [],
    this.perPage = 15,
    this.touches = const <String>[],
    this.withRelations = const <String>[],
    this.snakeAttributes,
    String? morphClass,
  }) : morphClass = morphClass ?? 'App\\Models\\$T',
       _relationFactories = relations,
       scopes = {
         for (final entry in scopes.entries)
           entry.key: (ModelQuery<Model> query, List<Object?> args) =>
               entry.value(query as ModelQuery<T>, args),
       },
       globalScopes = [
         for (final scope in globalScopes)
           (ModelQuery<Model> query) => scope(query as ModelQuery<T>),
       ],
       accessors = {
         for (final entry in accessors.entries)
           entry.key: (Model model) => entry.value(model as T),
       },
       mutators = {
         for (final entry in mutators.entries)
           entry.key: (Model model, Object? value) =>
               entry.value(model as T, value),
       };

  final String table;

  /// Laravel class name of the model (`App\Models\User` by default), used
  /// for polymorphic columns such as `personal_access_tokens.tokenable_type`
  /// and in [ModelNotFoundException] messages. Override it when the Laravel
  /// model lives elsewhere.
  final String morphClass;
  final T Function() factory;
  final String primaryKey;
  final KeyType keyType;
  final String? connection;
  final List<String> fillable;
  final List<String> guarded;
  final Map<String, Cast> casts;
  final List<String> hidden;
  final List<String> visible;
  final List<String> appends;
  final bool timestamps;
  final String createdAt;
  final String updatedAt;
  final bool softDeletes;
  final String deletedAt;

  /// Local scopes (wrapped to `Model`-typed functions).
  final Map<String, ScopeFn<Model>> scopes;

  /// Global scopes (wrapped to `Model`-typed functions).
  final List<GlobalScopeFn<Model>> globalScopes;

  /// Accessors (wrapped to `Model`-typed functions).
  final Map<String, AccessorFn<Model>> accessors;

  /// Mutators (wrapped to `Model`-typed functions).
  final Map<String, MutatorFn<Model>> mutators;

  final List<ModelObserver<T>> observers;
  final int perPage;

  /// Relations whose parent `updated_at` is touched when this model saves.
  final List<String> touches;

  /// Relations eager loaded on every query (`$with`).
  final List<String> withRelations;

  /// `public static $snakeAttributes` on one model: overrides
  /// [Model.snakeAttributes] when set.
  final bool? snakeAttributes;

  final Map<String, RelationFactory> _relationFactories;
  final Map<String, Relation<Model>> _relationCache = {};

  /// Names of the declared relations.
  Iterable<String> get relationNames => _relationFactories.keys;

  /// The relation named [name], or `null`.
  Relation<Model>? relation(String name) {
    final cached = _relationCache[name];
    if (cached != null) {
      return cached;
    }
    final factory = _relationFactories[name];
    if (factory == null) {
      return null;
    }
    return _relationCache[name] = factory()..name = name;
  }

  /// The relation named [name], or a [StateError].
  Relation<Model> requireRelation(String name) =>
      relation(name) ??
      (throw StateError('Model [$table] has no relation named [$name].'));

  /// Whether [key] may be mass assigned.
  bool isFillable(String key) {
    if (fillable.contains(key)) {
      return true;
    }
    if (fillable.isNotEmpty) {
      return false;
    }
    return !guarded.contains('*') && !guarded.contains(key);
  }

  /// Whether nothing is fillable (default: `guarded = ['*']`).
  bool get totallyGuarded => fillable.isEmpty && guarded.contains('*');

  /// Builds a model from a database row.
  T hydrate(Map<String, Object?> row, {DatabaseManager? db}) {
    final model = factory();
    model.hydrateFrom(row, db: db);
    return model;
  }

  /// Builds a new, unsaved model with [attributes] mass assigned.
  T newInstance([
    Map<String, Object?> attributes = const {},
    DatabaseManager? db,
  ]) {
    final model = factory()..attachDatabase(db);
    if (attributes.isNotEmpty) {
      model.fill(attributes);
    }
    return model;
  }

  /// A fresh query for this model.
  ModelQuery<T> query({DatabaseManager? db}) => ModelQuery<T>(this, db: db);

  /// Eager loads [relations] (list or map with constraints) on [models].
  Future<void> eagerLoad(
    List<Model> models,
    Object relations, {
    DatabaseManager? db,
  }) => ModelQuery<T>(
    this,
    db: db,
  ).loadRelationsOn(models, ModelQuery.parseWith(relations));
}
