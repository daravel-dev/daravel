import 'package:collection/collection.dart';

import '../../http/request.dart';
import '../../http/response.dart';
import 'model.dart';

/// A list of models with Laravel `Collection` conveniences.
final class ModelCollection<T extends Model> extends DelegatingList<T>
    implements JsonSerializable, Responsable {
  ModelCollection([List<T>? models]) : super(models ?? <T>[]);

  /// Primary keys in order.
  List<Object?> get modelKeys => [for (final model in this) model.key];

  /// Values of [attribute] in order.
  List<Object?> pluck(String attribute) => [
    for (final model in this) model.getAttr<Object?>(attribute),
  ];

  /// Models keyed by [attribute] (defaults to the primary key).
  Map<Object?, T> keyBy([String? attribute]) => {
    for (final model in this)
      attribute == null ? model.key : model.getAttr<Object?>(attribute): model,
  };

  /// Groups models by [attribute].
  Map<Object?, List<T>> groupBy(String attribute) {
    final groups = <Object?, List<T>>{};
    for (final model in this) {
      groups
          .putIfAbsent(model.getAttr<Object?>(attribute), () => <T>[])
          .add(model);
    }
    return groups;
  }

  /// Whether a model with the same table and key is present.
  bool containsModel(Model other) => any((model) => model.isSameAs(other));

  /// Eager loads [relations] on every model in the collection.
  Future<ModelCollection<T>> load(Object relations) async {
    if (isNotEmpty) {
      await first.modelDefinition.eagerLoad(
        this,
        relations,
        db: first.database,
      );
    }
    return this;
  }

  /// Loads [relations] only on models that do not have them yet.
  Future<ModelCollection<T>> loadMissing(List<String> relations) async {
    for (final relation in relations) {
      final pending = where(
        (model) => !model.relationLoaded(relation.split('.').first),
      ).toList();
      if (pending.isNotEmpty) {
        await pending.first.modelDefinition.eagerLoad(pending, [
          relation,
        ], db: pending.first.database);
      }
    }
    return this;
  }

  /// Hides [attributes] on every model.
  ModelCollection<T> makeHidden(List<String> attributes) {
    for (final model in this) {
      model.makeHidden(attributes);
    }
    return this;
  }

  /// Shows [attributes] on every model.
  ModelCollection<T> makeVisible(List<String> attributes) {
    for (final model in this) {
      model.makeVisible(attributes);
    }
    return this;
  }

  @override
  List<Map<String, Object?>> toJson() => [
    for (final model in this) model.toJson(),
  ];

  @override
  Response toResponse(Request request) => Response.json(toJson());
}
