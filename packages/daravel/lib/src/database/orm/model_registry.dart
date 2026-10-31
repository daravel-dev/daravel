import 'casts.dart';
import 'model.dart';
import 'model_definition.dart';
import 'relations.dart';

/// The application's models (`bootstrap/models.dart`, registered with
/// `ApplicationBuilder.withModels`): the explicit list that `model:show`,
/// `mcp:serve` and generators read instead of discovering classes.
final class ModelRegistry {
  ModelRegistry(Iterable<ModelDefinition<Model>> models)
    : models = List.unmodifiable(models);

  final List<ModelDefinition<Model>> models;

  /// The model whose class name (`Post`), morph class (`App\Models\Post`)
  /// or table (`posts`) is [name], ignoring case; `null` when none.
  ModelDefinition<Model>? find(String name) {
    final wanted = name.toLowerCase();
    for (final model in models) {
      if (modelClassName(model).toLowerCase() == wanted ||
          model.morphClass.toLowerCase() == wanted ||
          model.table.toLowerCase() == wanted) {
        return model;
      }
    }
    return null;
  }
}

/// The Dart class name of the models [definition] creates.
String modelClassName(ModelDefinition<Model> definition) =>
    definition.factory().runtimeType.toString();

/// [definition] as JSON-friendly data, in the spirit of `artisan model:show
/// --json` (database columns are added by the caller that can query them).
Map<String, Object?> describeModel(ModelDefinition<Model> definition) => {
  'class': modelClassName(definition),
  'table': definition.table,
  if (definition.connection != null) 'connection': definition.connection,
  'primaryKey': definition.primaryKey,
  'keyType': definition.keyType.name,
  'morphClass': definition.morphClass,
  'timestamps': definition.timestamps,
  'softDeletes': definition.softDeletes,
  'fillable': definition.fillable,
  'guarded': definition.guarded,
  'hidden': definition.hidden,
  if (definition.visible.isNotEmpty) 'visible': definition.visible,
  if (definition.appends.isNotEmpty) 'appends': definition.appends,
  'casts': {
    for (final MapEntry(:key, :value) in definition.casts.entries)
      key: castName(value),
  },
  if (definition.scopes.isNotEmpty) 'scopes': definition.scopes.keys.toList(),
  'relations': [
    for (final name in definition.relationNames)
      describeRelation(definition.requireRelation(name)),
  ],
  'observers': definition.observers.length,
};

/// The cast's name in Laravel's vocabulary (`integer`, `datetime`, ...).
String castName(Cast cast) => switch (cast) {
  IntCast() => 'integer',
  DoubleCast() => 'double',
  DecimalStringCast(:final places) => 'decimal:$places',
  BoolCast() => 'boolean',
  StringCast() => 'string',
  DateTimeCast() => 'datetime',
  DateTimeFormatCast(:final format) => 'datetime:$format',
  DateCast() => 'date',
  JsonCast() => 'json',
  VectorCast() => 'vector',
  EnumCast() => 'enum',
  CustomCast() => 'custom',
};

/// One relation: its name, type, related model and keys.
Map<String, Object?> describeRelation(Relation<Model> relation) {
  final type = relation.runtimeType.toString().split('<').first;
  return {
    'name': relation.name,
    'type': type,
    'related': switch (relation) {
      MorphTo(:final types) => [for (final t in types) modelClassName(t())],
      _ => modelClassName(relation.related),
    },
    ...switch (relation) {
      MorphToMany() => {
        'pivotTable': relation.pivotTable,
        'foreignPivotKey': relation.foreignPivotKey,
        'relatedPivotKey': relation.relatedPivotKey,
        'morphType': relation.morphType,
      },
      BelongsToMany() => {
        'pivotTable': relation.pivotTable,
        'foreignPivotKey': relation.foreignPivotKey,
        'relatedPivotKey': relation.relatedPivotKey,
      },
      MorphMany() => {
        'foreignKey': relation.foreignKey,
        'morphType': relation.morphType,
        'localKey': relation.localKey,
      },
      HasMany() => {
        'foreignKey': relation.foreignKey,
        'localKey': relation.localKey,
      },
      HasManyThrough() => {
        'through': modelClassName(relation.through()),
        'firstKey': relation.firstKey,
        'secondKey': relation.secondKey,
      },
      BelongsTo() => {
        'foreignKey': relation.foreignKey,
        'ownerKey': relation.ownerKey,
      },
      MorphTo() => {
        'foreignKey': relation.foreignKey,
        'morphType': relation.morphType,
      },
      _ => const <String, Object?>{},
    },
  };
}
