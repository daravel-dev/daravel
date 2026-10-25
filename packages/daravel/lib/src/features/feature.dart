import 'dart:async';
import 'dart:convert';

import '../auth/auth_manager.dart';
import '../auth/contracts.dart';
import '../database/database_manager.dart';
import '../database/orm/model.dart';
import '../database/orm/relations.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/clock.dart';
import '../foundation/container.dart';
import '../http/http_exceptions.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';

/// Resolves a feature's value for a scope (`null` for "no scope"). `false`
/// means inactive; any other value (`true`, a variant name) is active.
typedef FeatureResolver = FutureOr<Object?> Function(Object? scope);

/// A scope that knows its own stored form (Pennant's
/// `FeatureScopeSerializeable`).
abstract interface class FeatureScope {
  String featureScopeSerialize();
}

/// Where resolved feature values are kept.
abstract interface class FeatureStore {
  /// The stored value, or `(found: false, ...)`.
  Future<({bool found, Object? value})> get(String name, String scope);

  /// Stores [value] unless one is stored already; returns the stored value.
  Future<Object?> insert(String name, String scope, Object? value);

  Future<void> set(String name, String scope, Object? value);

  /// Changes the value of [name] for every scope already stored.
  Future<void> setForAllScopes(String name, Object? value);

  Future<void> delete(String name, String scope);

  /// Removes [names], or every feature.
  Future<void> purge([List<String>? names]);
}

/// Values in memory (Pennant's `array` driver): per isolate, lost on
/// restart. The default in tests.
final class ArrayFeatureStore implements FeatureStore {
  final Map<String, Map<String, Object?>> _values = {};

  @override
  Future<({bool found, Object? value})> get(String name, String scope) async {
    final values = _values[name];
    return values != null && values.containsKey(scope)
        ? (found: true, value: values[scope])
        : (found: false, value: null);
  }

  @override
  Future<Object?> insert(String name, String scope, Object? value) async =>
      (_values[name] ??= {}).putIfAbsent(scope, () => value);

  @override
  Future<void> set(String name, String scope, Object? value) async =>
      (_values[name] ??= {})[scope] = value;

  @override
  Future<void> setForAllScopes(String name, Object? value) async {
    final values = _values[name];
    if (values != null) {
      for (final scope in values.keys) {
        values[scope] = value;
      }
    }
  }

  @override
  Future<void> delete(String name, String scope) async =>
      _values[name]?.remove(scope);

  @override
  Future<void> purge([List<String>? names]) async {
    if (names == null) {
      _values.clear();
    } else {
      names.forEach(_values.remove);
    }
  }
}

/// Values in Pennant's `features` table (`name`, `scope`, JSON `value`), so a
/// Laravel application on the same database sees the same flags.
final class DatabaseFeatureStore implements FeatureStore {
  DatabaseFeatureStore(this.db, {this.table = 'features', this.connection});

  final DatabaseManager db;
  final String table;
  final String? connection;

  @override
  Future<({bool found, Object? value})> get(String name, String scope) async {
    final row = await db
        .table(table, connection: connection)
        .where('name', name)
        .where('scope', scope)
        .first();
    return row == null
        ? (found: false, value: null)
        : (found: true, value: jsonDecode('${row['value']}'));
  }

  @override
  Future<Object?> insert(String name, String scope, Object? value) async {
    final now = Clock.now();
    final inserted = await db
        .table(table, connection: connection)
        .insertOrIgnore({
          'name': name,
          'scope': scope,
          'value': jsonEncode(value),
          'created_at': now,
          'updated_at': now,
        });
    if (inserted > 0) {
      return value;
    }
    // Another request or a Laravel application stored it first.
    return (await get(name, scope)).value;
  }

  @override
  Future<void> set(String name, String scope, Object? value) async {
    final now = Clock.now();
    await db.table(table, connection: connection).upsert(
      [
        {
          'name': name,
          'scope': scope,
          'value': jsonEncode(value),
          'created_at': now,
          'updated_at': now,
        },
      ],
      ['name', 'scope'],
      ['value', 'updated_at'],
    );
  }

  @override
  Future<void> setForAllScopes(String name, Object? value) => db
      .table(table, connection: connection)
      .where('name', name)
      .update({'value': jsonEncode(value), 'updated_at': Clock.now()});

  @override
  Future<void> delete(String name, String scope) => db
      .table(table, connection: connection)
      .where('name', name)
      .where('scope', scope)
      .delete();

  @override
  Future<void> purge([List<String>? names]) {
    final query = db.table(table, connection: connection);
    return (names == null ? query : query.whereIn('name', names)).delete();
  }
}

final class _FeatureCache {
  final Map<String, Object?> values = {};
}

/// Feature flags (Laravel Pennant): resolvers, a [FeatureStore] and the
/// default scope (the authenticated user).
final class FeatureManager {
  FeatureManager(this.store, {Future<Object?> Function()? defaultScope})
    : _defaultScope = defaultScope ?? _authenticatedUser;

  final FeatureStore store;
  final Future<Object?> Function() _defaultScope;
  final Map<String, FeatureResolver> _resolvers = {};

  /// Serialize models with their morph alias (Pennant's `useMorphMap`)
  /// instead of their class (`App\Models\User|1`).
  bool useMorphMap = false;

  /// Defines [name]; [resolver] runs once per scope and its value is stored.
  void define(String name, FeatureResolver resolver) =>
      _resolvers[name] = resolver;

  /// The defined feature names.
  Iterable<String> get defined => _resolvers.keys;

  /// Pennant's `serializeScope`: `__laravel_null`, strings and numbers as
  /// they are, models as `<class>|<key>`, or a [FeatureScope]'s own form.
  String serializeScope(Object? scope) => switch (scope) {
    final FeatureScope custom => custom.featureScopeSerialize(),
    null => '__laravel_null',
    final String text => text,
    final num number => '$number',
    final Model model =>
      '${useMorphMap ? Relation.morphClassOf(model.modelDefinition) : model.modelDefinition.morphClass}|${model.key}',
    _ => throw StateError(
      'Unable to serialize the feature scope ${scope.runtimeType}; '
      'implement FeatureScope.',
    ),
  };

  /// The features for [scope] instead of the authenticated user.
  ScopedFeatures forScope(Object? scope) => ScopedFeatures._(this, scope);

  Future<ScopedFeatures> _current() async =>
      ScopedFeatures._(this, await _defaultScope());

  Future<Object?> value(String name) async => (await _current()).value(name);
  Future<bool> active(String name) async => (await _current()).active(name);
  Future<bool> inactive(String name) async => (await _current()).inactive(name);
  Future<bool> allAreActive(List<String> names) async =>
      (await _current()).allAreActive(names);
  Future<bool> someAreActive(List<String> names) async =>
      (await _current()).someAreActive(names);
  Future<void> activate(String name, [Object? value = true]) async =>
      (await _current()).activate(name, value);
  Future<void> deactivate(String name) async =>
      (await _current()).deactivate(name);
  Future<void> forget(String name) async => (await _current()).forget(name);

  /// Sets [value] for every scope that has a stored value.
  Future<void> activateForEveryone(String name, [Object? value = true]) async {
    await store.setForAllScopes(name, value);
    _cache()?.values.clear();
  }

  Future<void> deactivateForEveryone(String name) =>
      activateForEveryone(name, false);

  /// Removes the stored values of [names], or of every feature.
  Future<void> purge([List<String>? names]) async {
    await store.purge(names);
    _cache()?.values.clear();
  }

  Future<Object?> _resolve(String name, Object? scope) async {
    final key = serializeScope(scope);
    final cache = _cache();
    final cacheKey = '$name\u0000$key';
    if (cache != null && cache.values.containsKey(cacheKey)) {
      return cache.values[cacheKey];
    }
    final stored = await store.get(name, key);
    Object? value;
    if (stored.found) {
      value = stored.value;
    } else {
      final resolver = _resolvers[name];
      // An unknown feature is inactive and not stored (as Pennant).
      value = resolver == null
          ? false
          : await store.insert(name, key, await resolver(scope));
    }
    cache?.values[cacheKey] = value;
    return value;
  }

  void _forgetCached(String name, Object? scope) =>
      _cache()?.values.remove('$name\u0000${serializeScope(scope)}');

  /// Resolved values are kept for the rest of the request, job or command.
  static _FeatureCache? _cache() {
    final Scope? scope;
    try {
      scope = Container.current.currentScope;
    } on StateError {
      return null;
    }
    if (scope == null) {
      return null;
    }
    final existing = scope.get<_FeatureCache>();
    if (existing != null) {
      return existing;
    }
    final created = _FeatureCache();
    scope.put<_FeatureCache>(created);
    return created;
  }

  static Future<Object?> _authenticatedUser() async {
    try {
      return await Container.current
          .tryMake<AuthManager>()
          ?.user<Authenticatable>();
    } on Object {
      return null;
    }
  }
}

/// The features of one scope (`Feature.forScope(user)`).
final class ScopedFeatures {
  ScopedFeatures._(this._manager, this.scope);

  final FeatureManager _manager;
  final Object? scope;

  Future<Object?> value(String name) => _manager._resolve(name, scope);

  Future<Map<String, Object?>> values(List<String> names) async => {
    for (final name in names) name: await value(name),
  };

  Future<bool> active(String name) async => await value(name) != false;

  Future<bool> inactive(String name) async => await value(name) == false;

  Future<bool> allAreActive(List<String> names) async {
    for (final name in names) {
      if (!await active(name)) {
        return false;
      }
    }
    return true;
  }

  Future<bool> someAreActive(List<String> names) async {
    for (final name in names) {
      if (await active(name)) {
        return true;
      }
    }
    return false;
  }

  Future<void> activate(String name, [Object? value = true]) async {
    await _manager.store.set(name, _manager.serializeScope(scope), value);
    _manager._forgetCached(name, scope);
  }

  Future<void> deactivate(String name) => activate(name, false);

  /// Removes the stored value: the next check resolves it again.
  Future<void> forget(String name) async {
    await _manager.store.delete(name, _manager.serializeScope(scope));
    _manager._forgetCached(name, scope);
  }
}

/// Laravel Pennant's `Feature` facade over the application's
/// [FeatureManager].
abstract final class Feature {
  static FeatureManager get manager => Container.current.make<FeatureManager>();

  static void define(String name, FeatureResolver resolver) =>
      manager.define(name, resolver);

  static ScopedFeatures forScope(Object? scope) => manager.forScope(scope);

  static Future<Object?> value(String name) => manager.value(name);
  static Future<bool> active(String name) => manager.active(name);
  static Future<bool> inactive(String name) => manager.inactive(name);
  static Future<bool> allAreActive(List<String> names) =>
      manager.allAreActive(names);
  static Future<bool> someAreActive(List<String> names) =>
      manager.someAreActive(names);
  static Future<void> activate(String name, [Object? value = true]) =>
      manager.activate(name, value);
  static Future<void> deactivate(String name) => manager.deactivate(name);
  static Future<void> forget(String name) => manager.forget(name);
  static Future<void> activateForEveryone(
    String name, [
    Object? value = true,
  ]) => manager.activateForEveryone(name, value);
  static Future<void> deactivateForEveryone(String name) =>
      manager.deactivateForEveryone(name);
  static Future<void> purge([List<String>? names]) => manager.purge(names);
}

/// `feature:a,b` (Pennant's `EnsureFeaturesAreActive`): `400 Bad Request`
/// unless every feature is active for the authenticated user.
final class EnsureFeaturesAreActive implements Middleware {
  const EnsureFeaturesAreActive(this.features, {this.debug = false});

  final List<String> features;

  /// Names the missing features in the error (Pennant does with `APP_DEBUG`).
  final bool debug;

  @override
  Future<Response> handle(Request request, Next next) async {
    if (!await Feature.allAreActive(features)) {
      throw HttpException(
        400,
        debug ? 'Required features [${features.join(', ')}] not enabled.' : '',
      );
    }
    return next(request);
  }
}

/// Pennant's `features` table (`2022_11_01_000001_create_features_table`).
final class CreateFeaturesTable extends Migration {
  const CreateFeaturesTable();

  @override
  String get name => '2022_11_01_000001_create_features_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('features', (table) {
    table.id();
    table.string('name');
    table.string('scope');
    table.text('value');
    table.timestamps();
    table.unique(['name', 'scope']);
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('features');
}
