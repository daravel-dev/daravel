import 'dart:async';

import '../database_manager.dart';
import '../orm/model.dart';
import '../orm/model_collection.dart';
import '../orm/model_definition.dart';
import 'faker.dart';

/// Produces default attributes for a model (`definition()` in Laravel).
typedef FactoryDefinition = Map<String, Object?> Function(Faker faker);

/// A state transformation (`state()`): receives the faker, returns overrides.
typedef FactoryState = Map<String, Object?> Function(Faker faker);

/// Model factory (named `ModelFactory` because `ModelFactory` is the container
/// binding typedef; BLUEPRINT_V2 §7.5.6).
///
/// ```dart
/// final userFactory = ModelFactory<User>(
///   User.definition,
///   (f) => {'name': f.name(), 'email': f.email(), 'password': 'secret'},
///   states: {'admin': (f) => {'role': 'admin'}},
/// );
/// await userFactory.count(3).state('admin').create();
/// ```
final class ModelFactory<T extends Model> {
  ModelFactory(
    this.definition,
    this._define, {
    this.states = const <String, FactoryState>{},
    Faker? faker,
    DatabaseManager? db,
  }) : faker = faker ?? Faker(),
       _db = db;

  final ModelDefinition<T> definition;
  final FactoryDefinition _define;

  /// Named states usable via `state('admin')`.
  final Map<String, FactoryState> states;
  final Faker faker;
  final DatabaseManager? _db;

  int _count = 1;
  final List<FactoryState> _appliedStates = <FactoryState>[];
  List<Map<String, Object?>>? _sequence;
  final List<FutureOr<void> Function(T model)> _afterMaking = [];
  final List<FutureOr<void> Function(T model)> _afterCreating = [];

  ModelFactory<T> _copy() =>
      ModelFactory<T>(
          definition,
          _define,
          states: states,
          faker: faker,
          db: _db,
        )
        .._count = _count
        .._appliedStates.addAll(_appliedStates)
        .._sequence = _sequence
        .._afterMaking.addAll(_afterMaking)
        .._afterCreating.addAll(_afterCreating);

  /// Number of models produced by `make()`/`create()` plural variants.
  ModelFactory<T> count(int count) => _copy().._count = count;

  /// Applies a state: a named state, a map of overrides or a closure.
  ModelFactory<T> state(Object state) {
    final copy = _copy();
    switch (state) {
      case String():
        final named = states[state];
        if (named == null) {
          throw ArgumentError.value(state, 'state', 'Unknown factory state');
        }
        copy._appliedStates.add(named);
      case Map<String, Object?>():
        copy._appliedStates.add((_) => state);
      case FactoryState():
        copy._appliedStates.add(state);
      default:
        throw ArgumentError.value(
          state,
          'state',
          'Expected a name, Map or closure',
        );
    }
    return copy;
  }

  /// Cycles through [values] for successive models.
  ModelFactory<T> sequence(List<Map<String, Object?>> values) =>
      _copy().._sequence = values;

  ModelFactory<T> afterMaking(FutureOr<void> Function(T model) callback) =>
      _copy().._afterMaking.add(callback);

  ModelFactory<T> afterCreating(FutureOr<void> Function(T model) callback) =>
      _copy().._afterCreating.add(callback);

  /// Raw attributes for the [index]-th model.
  Map<String, Object?> raw([
    Map<String, Object?> overrides = const {},
    int index = 0,
  ]) {
    final attributes = <String, Object?>{..._define(faker)};
    for (final state in _appliedStates) {
      attributes.addAll(state(faker));
    }
    final sequence = _sequence;
    if (sequence != null && sequence.isNotEmpty) {
      attributes.addAll(sequence[index % sequence.length]);
    }
    attributes.addAll(overrides);
    return attributes;
  }

  /// Builds one unsaved model.
  Future<T> make([Map<String, Object?> overrides = const {}]) async =>
      (await makeMany(overrides, 1)).first;

  /// Builds [count] (or `count()`) unsaved models.
  Future<ModelCollection<T>> makeMany([
    Map<String, Object?> overrides = const {},
    int? count,
  ]) async {
    final models = ModelCollection<T>();
    for (var i = 0; i < (count ?? _count); i++) {
      final model = definition.factory()..attachDatabase(_db);
      model.forceFill(raw(overrides, i));
      for (final callback in _afterMaking) {
        await callback(model);
      }
      models.add(model);
    }
    return models;
  }

  /// Builds and saves one model.
  Future<T> create([Map<String, Object?> overrides = const {}]) async =>
      (await createMany(overrides, 1)).first;

  /// Builds and saves [count] (or `count()`) models.
  Future<ModelCollection<T>> createMany([
    Map<String, Object?> overrides = const {},
    int? count,
  ]) async {
    final models = await makeMany(overrides, count);
    for (final model in models) {
      await model.save();
      for (final callback in _afterCreating) {
        await callback(model);
      }
    }
    return models;
  }
}
