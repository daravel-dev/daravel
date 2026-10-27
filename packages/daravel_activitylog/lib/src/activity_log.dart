import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'activity.dart';
import 'config.dart';
import 'logs_activity.dart';

const Object _disabledKey = #daravelActivityLogDisabled;
const Object _causerKey = #daravelActivityLogCauser;
const Object _batchKey = #daravelActivityLogBatch;

/// A causer chosen with [ActivityLog.causedBy]; `null` inside means
/// anonymous, which differs from no choice at all.
final class _Causer {
  const _Causer(this.model);
  final Model? model;
}

/// Switches and lookups of the activity log (Spatie's `ActivityLogStatus`
/// and `CauserResolver`). What Spatie keeps in singletons (a disabled log, a
/// forced causer, an open batch) is scoped to a zone here, so one request
/// never switches logging off for the requests running beside it.
abstract final class ActivityLog {
  /// The application's [ActivityLogConfig], or the defaults when
  /// `withActivityLog()` was not called.
  static ActivityLogConfig get config {
    final container = Container.current;
    if (container.bound<ConfigRepository>()) {
      final repository = container.make<ConfigRepository>();
      if (repository.hasSection<ActivityLogConfig>()) {
        return repository.section<ActivityLogConfig>();
      }
    }
    return const ActivityLogConfig();
  }

  /// Whether activities are dropped here: `ACTIVITY_LOGGER_ENABLED=false`,
  /// or inside [withoutLogs].
  static bool get disabled =>
      Zone.current[_disabledKey] == true || !config.enabled;

  /// Runs [body] without logging anything (Spatie's
  /// `activity()->withoutLogs()`).
  static Future<R> withoutLogs<R>(FutureOr<R> Function() body) =>
      runZoned(() async => body(), zoneValues: {_disabledKey: true});

  /// Runs [body] with [causer] as the causer of every activity it logs
  /// (Spatie's `CauserResolver::setCauser()`); `null` logs them as
  /// anonymous.
  static Future<R> causedBy<R>(Model? causer, FutureOr<R> Function() body) =>
      runZoned(() async => body(), zoneValues: {_causerKey: _Causer(causer)});

  /// The causer of an activity that does not name one: the one set with
  /// [causedBy], else the authenticated user of [ActivityLogConfig.authGuard]
  /// (the request's guard when unset), when that user is a model.
  static Future<Model?> resolveCauser() async {
    if (Zone.current[_causerKey] case final _Causer causer) {
      return causer.model;
    }
    final container = Container.current;
    if (!container.bound<AuthManager>()) {
      return null;
    }
    final auth = container.make<AuthManager>();
    final guard = config.authGuard;
    if (guard != null && !auth.hasGuard(guard)) {
      return null;
    }
    try {
      final user = await auth.user<Authenticatable>(guard: guard);
      return user is Model ? user as Model : null;
    } on StateError {
      // No such guard, or no request: a command or a job logs anonymously.
      return null;
    }
  }

  /// The model stored as [type] in a `*_type` column: its morph alias
  /// ([Relation.morphMap]) or a model of `withModels(...)` whose morph class
  /// is [type]; `null` when none.
  static ModelDefinition<Model>? definitionFor(String type) {
    final mapped = Relation.morphedModel(type);
    if (mapped != null) {
      return mapped;
    }
    final container = Container.current;
    if (container.bound<ModelRegistry>()) {
      for (final model in container.make<ModelRegistry>().models) {
        if (model.morphClass == type || Relation.morphClassOf(model) == type) {
          return model;
        }
      }
    }
    return null;
  }

  /// The models `subject` and `causer` may point at, for eager loading.
  static List<ModelDefinition<Model> Function()> knownModels() {
    final container = Container.current;
    if (!container.bound<ModelRegistry>()) {
      return const [];
    }
    return [
      for (final model in container.make<ModelRegistry>().models) () => model,
    ];
  }
}

/// Groups the activities of one operation under a `batch_uuid` (Spatie's
/// `LogBatch`).
///
/// ```dart
/// await LogBatch.within((uuid) async {
///   await session.update({'status': 'finished'});
///   await score.update({'total': 90});
/// });
/// ```
abstract final class LogBatch {
  /// The open batch's UUID, or `null`.
  static String? get uuid => Zone.current[_batchKey] as String?;

  static bool get isOpen => uuid != null;

  /// Runs [body] in a batch: every activity logged inside shares one UUID.
  /// A batch opened inside another one keeps the outer UUID, as Spatie's
  /// nested `startBatch()` calls do.
  static Future<R> within<R>(FutureOr<R> Function(String uuid) body) {
    final id = uuid ?? Str.uuid();
    return runZoned(() async => body(id), zoneValues: {_batchKey: id});
  }

  /// Runs [body] in the batch [id] (Spatie's `setBatch()`), to continue a
  /// batch started elsewhere, such as in the job a request dispatched.
  static Future<R> using<R>(String id, FutureOr<R> Function() body) =>
      runZoned(() async => body(), zoneValues: {_batchKey: id});
}

/// A new activity in the log [logName] (the default log when null), as
/// Spatie's `activity()` helper:
///
/// ```dart
/// await activity('security')
///     .performedOn(examSession)
///     .withProperties({'ip': request.ip})
///     .log('Exam session locked after a tab switch');
/// ```
ActivityLogger activity([String? logName]) => ActivityLogger(logName);

/// The builder behind [activity] (Spatie's `ActivityLogger`).
final class ActivityLogger {
  ActivityLogger([String? logName])
    : _logName = logName ?? ActivityLog.config.defaultLogName;

  String? _logName;
  Model? _subject;
  _Causer? _causer;
  String? _event;
  Map<String, Object?> _properties = {};
  DateTime? _createdAt;
  final List<void Function(Activity activity)> _taps = [];

  ActivityLogger useLog(String? logName) {
    _logName = logName;
    return this;
  }

  ActivityLogger inLog(String? logName) => useLog(logName);

  /// The model the activity is about (`subject_type`, `subject_id`).
  ActivityLogger performedOn(Model subject) {
    _subject = subject;
    return this;
  }

  ActivityLogger on(Model subject) => performedOn(subject);

  /// The model that caused the activity (`causer_type`, `causer_id`);
  /// `null` keeps the default, the authenticated user.
  ActivityLogger causedBy(Model? causer) {
    if (causer != null) {
      _causer = _Causer(causer);
    }
    return this;
  }

  ActivityLogger by(Model? causer) => causedBy(causer);

  /// No causer, even when a user is authenticated.
  ActivityLogger causedByAnonymous() {
    _causer = const _Causer(null);
    return this;
  }

  ActivityLogger byAnonymous() => causedByAnonymous();

  ActivityLogger event(String event) {
    _event = event;
    return this;
  }

  ActivityLogger setEvent(String event) => this.event(event);

  /// Replaces the properties (stored as JSON).
  ActivityLogger withProperties(Map<String, Object?> properties) {
    _properties = Map.of(properties);
    return this;
  }

  ActivityLogger withProperty(String key, Object? value) {
    _properties[key] = value;
    return this;
  }

  ActivityLogger createdAt(DateTime dateTime) {
    _createdAt = dateTime;
    return this;
  }

  /// Changes the activity before it is saved.
  ActivityLogger tap(void Function(Activity activity) callback) {
    _taps.add(callback);
    return this;
  }

  /// Saves the activity with [description], where `:subject.name`,
  /// `:causer.name` and `:properties.key` are replaced by those values.
  /// Returns `null` when logging is disabled ([ActivityLog.disabled]).
  Future<Activity?> log(String description) async {
    if (ActivityLog.disabled) {
      return null;
    }
    final activity = Activity.definition.factory();
    final causer = _causer != null
        ? _causer!.model
        : await ActivityLog.resolveCauser();
    activity
      ..setAttr('log_name', _logName)
      ..setAttr('event', _event)
      ..setAttr('batch_uuid', LogBatch.uuid);
    if (_subject case final subject?) {
      activity
        ..setAttr(
          'subject_type',
          Relation.morphClassOf(subject.modelDefinition),
        )
        ..setAttr('subject_id', subject.key);
    }
    if (causer != null) {
      activity
        ..setAttr('causer_type', Relation.morphClassOf(causer.modelDefinition))
        ..setAttr('causer_id', causer.key);
    }
    activity.setAttr('properties', encodeProperties(_properties));
    if (_createdAt case final createdAt?) {
      activity.setAttr('created_at', formatDateTime(createdAt));
    }
    for (final tap in _taps) {
      tap(activity);
    }
    activity.setAttr(
      'description',
      _replacePlaceholders(
        activity.hasAttribute('description')
            ? activity.description
            : description,
        subject: _subject,
        causer: causer,
        properties: _properties,
      ),
    );
    if (_subject case final LogsActivity subject) {
      subject.tapActivity(activity, _event ?? '');
    }
    await activity.save();
    return activity;
  }

  /// `:subject.name`, `:causer.email`, `:properties.ip`: Spatie's pattern,
  /// left as it is when the value is missing.
  static String _replacePlaceholders(
    String description, {
    Model? subject,
    Model? causer,
    Map<String, Object?> properties = const {},
  }) => description.replaceAllMapped(
    RegExp(r':[a-z0-9._-]+(?<![.])', caseSensitive: false),
    (match) {
      final text = match[0]!;
      final dot = text.indexOf('.');
      if (dot < 0) {
        return text;
      }
      final root = switch (text.substring(1, dot)) {
        'subject' => subject,
        'causer' => causer,
        'properties' => properties,
        _ => null,
      };
      final value = dataGet(root, text.substring(dot + 1));
      return value == null ? text : '$value';
    },
  );
}

/// [properties] as Spatie's `collection` cast stores them: an empty
/// collection is `[]`, dates are ISO-8601 as Laravel serializes them.
String encodeProperties(Map<String, Object?> properties) => properties.isEmpty
    ? '[]'
    : jsonEncode(
        properties,
        toEncodable: (value) => switch (value) {
          DateTime() => jsonDate(value),
          Model() => value.toJson(),
          Enum() => value.name,
          _ => value.toString(),
        },
      );
