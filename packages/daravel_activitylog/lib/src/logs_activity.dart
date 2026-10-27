import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:daravel/daravel.dart';

import 'activity.dart';
import 'activity_log.dart';
import 'log_options.dart';

/// Logs a model's changes (Spatie's `LogsActivity` trait). Daravel has no
/// boot hooks, so the model also lists an [ActivityLogObserver]:
///
/// ```dart
/// final class Assessment extends Model with LogsActivity {
///   static final ModelDefinition<Assessment> definition = ModelDefinition(
///     table: 'assessments',
///     factory: Assessment.new,
///     observers: [ActivityLogObserver<Assessment>()],
///   );
///
///   @override
///   LogOptions get activitylogOptions =>
///       LogOptions.defaults().logOnly(['score', 'status']).logOnlyDirty();
/// }
/// ```
base mixin LogsActivity on Model {
  /// What to record (Spatie's `getActivitylogOptions()`).
  LogOptions get activitylogOptions;

  bool _loggingEnabled = true;

  /// Whether this instance's events are logged ([disableLogging]).
  bool get enableLoggingModelsEvents => _loggingEnabled;

  /// Stops logging this instance's events.
  LogsActivity disableLogging() {
    _loggingEnabled = false;
    return this;
  }

  LogsActivity enableLogging() {
    _loggingEnabled = true;
    return this;
  }

  /// The activities about this model.
  ModelQuery<Activity> activities() => Activity.query().forSubject(this);

  /// Changes an activity about this model before it is saved.
  void tapActivity(Activity activity, String eventName) {}
}

/// The activities a model caused (Spatie's `CausesActivity`), typically a
/// user.
base mixin CausesActivity on Model {
  ModelQuery<Activity> actions() => Activity.query().causedBy(this);
}

/// Records the events of a [LogsActivity] model: `created`, `updated`,
/// `deleted`, and `restored` when it soft deletes, as Spatie does.
/// [recordEvents] replaces that list (Spatie's `$recordEvents`) and
/// [doNotRecordEvents] removes from it.
///
/// The activity is written in the model's transaction, so a rollback
/// removes it with the change it describes.
final class ActivityLogObserver<T extends Model> extends ModelObserver<T> {
  const ActivityLogObserver({
    this.recordEvents,
    this.doNotRecordEvents = const [],
  });

  final List<String>? recordEvents;
  final List<String> doNotRecordEvents;

  static final Expando<Map<String, Object?>> _oldAttributes = Expando();

  List<String> eventsToBeRecorded(Model model) => [
    for (final event
        in recordEvents ??
            [
              'created',
              'updated',
              'deleted',
              if (model.modelDefinition.softDeletes) 'restored',
            ])
      if (!doNotRecordEvents.contains(event)) event,
  ];

  static LogsActivity _logging(Model model) => model is LogsActivity
      ? model
      : throw StateError(
          'ActivityLogObserver is listed on ${model.runtimeType}, which does '
          'not mix in LogsActivity.',
        );

  /// Keeps the values before the update: by `updated`, the model's
  /// original matches its new attributes.
  @override
  Future<bool?> updating(T model) async {
    if (eventsToBeRecorded(model).contains('updated')) {
      final before = model.modelDefinition.factory()
        ..hydrateFrom(Map.of(model.original));
      _oldAttributes[model] = await logChanges(
        before,
        _logging(model).activitylogOptions,
      );
    }
    return null;
  }

  @override
  Future<bool?> created(T model) => _record(model, 'created');

  @override
  Future<bool?> updated(T model) => _record(model, 'updated');

  @override
  Future<bool?> deleted(T model) => _record(model, 'deleted');

  @override
  Future<bool?> restored(T model) => _record(model, 'restored');

  Future<bool?> _record(T model, String event) async {
    if (!eventsToBeRecorded(model).contains(event)) {
      return null;
    }
    final logging = _logging(model);
    final options = logging.activitylogOptions;
    final old = _oldAttributes[model];
    _oldAttributes[model] = null;
    if (!_shouldLogEvent(logging, event, options)) {
      return null;
    }
    final changes = await attributeValuesToBeLogged(
      model,
      event,
      options,
      oldAttributes: old ?? const {},
      events: eventsToBeRecorded(model),
    );
    final description = options.descriptionForEvent?.call(event) ?? event;
    if (description.isEmpty) {
      return null;
    }
    final empty = _isEmpty(changes['attributes']) && _isEmpty(changes['old']);
    if (empty && !options.submitsEmptyLogs) {
      return null;
    }
    await activity(options.logName)
        .event(event)
        .performedOn(model)
        .withProperties(changes)
        .log(description);
    return null;
  }

  static bool _isEmpty(Object? value) =>
      value == null || (value is Map && value.isEmpty);

  bool _shouldLogEvent(LogsActivity model, String event, LogOptions options) {
    if (!model.enableLoggingModelsEvents || ActivityLog.disabled) {
      return false;
    }
    if (event != 'created' && event != 'updated') {
      return true;
    }
    // What Laravel's getDirty() holds during these events.
    final changed = model.getChanges();
    final definition = model.modelDefinition;
    // A restore saves deleted_at alone; `restored` describes it.
    if (definition.softDeletes &&
        changed.containsKey(definition.deletedAt) &&
        changed.length == 1) {
      return false;
    }
    return changed.keys.any((key) => !options.ignoredChanges.contains(key));
  }
}

/// The `attributes` (and on updates `old`) Spatie stores for [event]
/// (`attributeValuesToBeLogged`): the logged attributes as the database
/// holds them after the change, read again as Spatie does (`fresh()`), so
/// defaults filled by the database are included.
Future<Map<String, Object?>> attributeValuesToBeLogged(
  Model model,
  String event,
  LogOptions options, {
  Map<String, Object?> oldAttributes = const {},
  List<String> events = const ['created', 'updated', 'deleted'],
}) async {
  if (attributesToBeLogged(model, options).isEmpty) {
    return {};
  }
  final source = model.exists ? await model.fresh() ?? model : model;
  var attributes = await logChanges(source, options);
  Map<String, Object?>? old;
  if (events.contains('updated') && event == 'updated') {
    old = {for (final key in attributes.keys) key: null, ...oldAttributes};
  }
  if (options.onlyDirty && old != null) {
    final before = old;
    attributes = {
      for (final MapEntry(:key, :value) in attributes.entries)
        if (!before.containsKey(key) ||
            !const DeepCollectionEquality().equals(value, before[key]))
          key: value,
    };
    old = {
      for (final key in attributes.keys)
        if (before.containsKey(key)) key: before[key],
    };
  }
  if (events.contains('deleted') && event == 'deleted') {
    return {'old': attributes};
  }
  return {'attributes': attributes, 'old': ?old};
}

/// The attributes [options] log for [model] (Spatie's
/// `attributesToBeLogged`), in order and without repeats.
List<String> attributesToBeLogged(Model model, LogOptions options) {
  final definition = model.modelDefinition;
  final attributes = <String>{};
  if (options.logsFillable) {
    attributes.addAll(definition.fillable);
  }
  if (options.logsUnguarded && !definition.guarded.contains('*')) {
    attributes.addAll(
      model.attributes.keys.where((key) => !definition.guarded.contains(key)),
    );
  }
  if (options.attributes.isNotEmpty) {
    attributes.addAll(options.attributes.where((name) => name != '*'));
    if (options.attributes.contains('*')) {
      attributes.addAll(model.attributes.keys);
    }
  }
  attributes.removeAll(options.exceptAttributes);
  return attributes.toList();
}

/// The values of the logged attributes of [model] (Spatie's `logChanges`):
/// casts and accessors applied, dates as Laravel serializes them
/// (`2026-01-02T03:04:05.000000Z`), enums as stored.
Future<Map<String, Object?>> logChanges(Model model, LogOptions options) async {
  final changes = <String, Object?>{};
  for (final attribute in attributesToBeLogged(model, options)) {
    if (attribute.contains('->')) {
      _setPath(
        changes,
        attribute.replaceAll('->', '.').split('.'),
        _jsonValue(model, attribute),
      );
      continue;
    }
    if (attribute.contains('.')) {
      for (final MapEntry(:key, :value) in (await _relatedValue(
        model,
        attribute,
      )).entries) {
        changes.putIfAbsent(key, () => value);
      }
      continue;
    }
    changes[attribute] = _value(
      model,
      attribute,
      raw: options.rawValues.contains(attribute),
    );
  }
  return changes;
}

Object? _value(Model model, String attribute, {bool raw = false}) {
  final value = raw
      ? model.attributes[attribute]
      : model.getAttr<Object?>(attribute);
  if (value == null) {
    return null;
  }
  if (_isDate(model.modelDefinition, attribute) || value is DateTime) {
    final date = value is DateTime ? value : parseDateTime(value);
    return date == null ? value : jsonDate(date);
  }
  if (value is Enum) {
    return model.attributes[attribute];
  }
  return value;
}

bool _isDate(ModelDefinition<Model> definition, String attribute) =>
    (definition.timestamps &&
        (attribute == definition.createdAt ||
            attribute == definition.updatedAt)) ||
    (definition.softDeletes && attribute == definition.deletedAt) ||
    definition.casts[attribute] is DateTimeCast ||
    definition.casts[attribute] is DateCast;

/// `author.name` or `author.company.name`: the relations are loaded when
/// they were not.
Future<Map<String, Object?>> _relatedValue(
  Model model,
  String attribute,
) async {
  final names = attribute.split('.');
  final column = names.removeLast();
  Model? current = model;
  final path = <String>[];
  for (final name in names) {
    final relation = _relationName(current!, name);
    path.add(relation);
    if (!current.relationLoaded(relation)) {
      await current.load(relation);
    }
    current = current.related<Model?>(relation);
    if (current == null) {
      break;
    }
  }
  final value = current?.getAttr<Object?>(column);
  return {
    [...path, column].join('.'): value is DateTime ? jsonDate(value) : value,
  };
}

String _relationName(Model model, String name) {
  final declared = model.modelDefinition.relationNames.toSet();
  return [
        name,
        Str.snake(name),
        Str.camel(name),
      ].firstWhereOrNull(declared.contains) ??
      name;
}

/// `meta->color` or `meta->colors.main`: a value inside a JSON attribute.
Object? _jsonValue(Model model, String attribute) {
  final [column, ...path] = attribute.split('->');
  var value = model.getAttr<Object?>(column);
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  return dataGet(value, path.join('->').replaceAll('->', '.'));
}

void _setPath(Map<String, Object?> target, List<String> path, Object? value) {
  var current = target;
  for (final key in path.take(path.length - 1)) {
    current = switch (current[key]) {
      final Map<String, Object?> nested => nested,
      _ => current[key] = <String, Object?>{},
    };
  }
  current[path.last] = value;
}
