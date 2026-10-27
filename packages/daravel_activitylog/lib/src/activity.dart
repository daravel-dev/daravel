import 'package:daravel/daravel.dart';

import 'activity_log.dart';
import 'config.dart';

/// A row of `activity_log` (Spatie's `Activity` model), in the table and
/// connection of [ActivityLogConfig].
final class Activity extends Model {
  static final Map<String, ModelDefinition<Activity>> _definitions = {};

  /// The definition for the current [ActivityLogConfig]'s table and
  /// connection.
  static ModelDefinition<Activity> get definition {
    final config = ActivityLog.config;
    return _definitions.putIfAbsent(
      '${config.connection}|${config.tableName}',
      () => ModelDefinition<Activity>(
        table: config.tableName,
        connection: config.connection,
        factory: Activity.new,
        guarded: const [],
        casts: const {'properties': Cast.json},
        morphClass: r'Spatie\Activitylog\Models\Activity',
        relations: {
          'subject': () =>
              MorphTo(morphName: 'subject', types: ActivityLog.knownModels()),
          'causer': () =>
              MorphTo(morphName: 'causer', types: ActivityLog.knownModels()),
        },
      ),
    );
  }

  @override
  ModelDefinition<Activity> get modelDefinition => Activity.definition;

  static ModelQuery<Activity> query() => definition.query();

  int get id => getAttr<num>('id').toInt();
  String? get logName => getAttr('log_name');
  String get description => getAttr('description');
  String? get subjectType => getAttr('subject_type');
  Object? get subjectId => getAttr('subject_id');
  String? get event => getAttr('event');
  String? get causerType => getAttr('causer_type');
  Object? get causerId => getAttr('causer_id');
  String? get batchUuid => getAttr('batch_uuid');
  DateTime? get createdAt => parseDateTime(getAttr<Object?>('created_at'));

  /// The stored properties; `{}` for Spatie's empty `[]`.
  Map<String, Object?> get properties =>
      switch (getAttr<Object?>('properties')) {
        final Map<String, Object?> map => map,
        _ => const {},
      };

  /// The `attributes` and `old` of a model change (Spatie's `changes()`).
  Map<String, Object?> get changes => {
    for (final key in const ['attributes', 'old'])
      if (properties.containsKey(key)) key: properties[key],
  };

  /// The property at the dot [path] (Spatie's `getExtraProperty()`).
  Object? getExtraProperty(String path, [Object? defaultValue]) =>
      dataGet(properties, path) ?? defaultValue;

  /// The model the activity is about, or `null` (also when it was deleted).
  /// Its type must be a model of `withModels(...)` or of
  /// [Relation.morphMap]; there is no reflection to find it otherwise.
  Future<Model?> subject() => _resolve(
    'subject',
    subjectType,
    subjectId,
    withTrashed: ActivityLog.config.subjectReturnsSoftDeletedModels,
  );

  /// The model that caused the activity, or `null`.
  Future<Model?> causer() => _resolve('causer', causerType, causerId);

  Future<Model?> _resolve(
    String relation,
    String? type,
    Object? id, {
    bool withTrashed = false,
  }) async {
    if (relationLoaded(relation)) {
      return related<Model?>(relation);
    }
    if (type == null || id == null) {
      return null;
    }
    final definition =
        ActivityLog.definitionFor(type) ??
        (throw StateError(
          'Cannot resolve the $relation type [$type]: list its model in '
          'withModels(...) or register it with Relation.morphMap().',
        ));
    var query = definition.query();
    if (withTrashed && definition.softDeletes) {
      query = query.withTrashed();
    }
    final model = await query.whereKey(id).first();
    setRelation(relation, model);
    return model;
  }

  /// Timestamps in Laravel's format, so rows written by Daravel and by a
  /// Laravel application sharing the table compare and sort alike.
  @override
  Future<bool> save() {
    if (!exists) {
      final now = formatDateTime(Clock.now());
      if (getAttr<Object?>('created_at') == null) {
        setAttr('created_at', now);
      }
      setAttr('updated_at', getAttr<Object?>('updated_at') ?? now);
    }
    return super.save();
  }
}

/// Spatie's `Activity` scopes.
extension ActivityQuery on ModelQuery<Activity> {
  /// Activities of the log [names] (a name or a list of names).
  ModelQuery<Activity> inLog(Object names) => whereIn(
    'log_name',
    names is Iterable<Object?> ? names.toList() : [names],
  );

  ModelQuery<Activity> causedBy(Model causer) => where(
    'causer_type',
    Relation.morphClassOf(causer.modelDefinition),
  ).where('causer_id', causer.key);

  ModelQuery<Activity> forSubject(Model subject) => where(
    'subject_type',
    Relation.morphClassOf(subject.modelDefinition),
  ).where('subject_id', subject.key);

  ModelQuery<Activity> forEvent(String event) => where('event', event);

  ModelQuery<Activity> hasBatch() => whereNotNull('batch_uuid');

  ModelQuery<Activity> forBatch(String uuid) => where('batch_uuid', uuid);
}
