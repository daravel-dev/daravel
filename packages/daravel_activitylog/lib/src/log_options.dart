/// What a `LogsActivity` model records (Spatie's `LogOptions`), with
/// Spatie's builder methods:
///
/// ```dart
/// @override
/// LogOptions get activitylogOptions => LogOptions.defaults()
///     .logOnly(['title', 'score', 'status'])
///     .logOnlyDirty()
///     .dontSubmitEmptyLogs()
///     .useLogName('assessments');
/// ```
///
/// Dart has no property and method of one name, so the settings read back
/// under their own names ([logsFillable], [onlyDirty], ...).
final class LogOptions {
  LogOptions();

  /// Spatie's starting point: no attributes, empty logs submitted.
  factory LogOptions.defaults() => LogOptions();

  String? _logName;
  bool _submitEmptyLogs = true;
  bool _logFillable = false;
  bool _logOnlyDirty = false;
  bool _logUnguarded = false;
  List<String> _logAttributes = const [];
  List<String> _logExceptAttributes = const [];
  List<String> _dontLogIfAttributesChangedOnly = const [];
  List<String> _attributeRawValues = const [];
  String Function(String eventName)? _descriptionForEvent;

  /// The log name ([useLogName]); the default log when null.
  String? get logName => _logName;
  bool get submitsEmptyLogs => _submitEmptyLogs;
  bool get logsFillable => _logFillable;
  bool get onlyDirty => _logOnlyDirty;
  bool get logsUnguarded => _logUnguarded;
  List<String> get attributes => _logAttributes;
  List<String> get exceptAttributes => _logExceptAttributes;
  List<String> get ignoredChanges => _dontLogIfAttributesChangedOnly;
  List<String> get rawValues => _attributeRawValues;
  String Function(String eventName)? get descriptionForEvent =>
      _descriptionForEvent;

  /// Every attribute of the model (`*`), hidden ones included: combine
  /// with [logExcept] for passwords and tokens.
  LogOptions logAll() => logOnly(const ['*']);

  /// The attributes not in the model's `guarded`.
  LogOptions logUnguarded() {
    _logUnguarded = true;
    return this;
  }

  /// The model's `fillable` attributes.
  LogOptions logFillable() {
    _logFillable = true;
    return this;
  }

  LogOptions dontLogFillable() {
    _logFillable = false;
    return this;
  }

  /// On updates, only the logged attributes that changed (with their old
  /// values).
  LogOptions logOnlyDirty() {
    _logOnlyDirty = true;
    return this;
  }

  /// These attributes; `relation.column` and `column->json.path` are
  /// understood, `*` is every attribute.
  LogOptions logOnly(List<String> attributes) {
    _logAttributes = List.of(attributes);
    return this;
  }

  LogOptions logExcept(List<String> attributes) {
    _logExceptAttributes = List.of(attributes);
    return this;
  }

  /// No activity when only these attributes changed (`updated_at`, a
  /// counter).
  LogOptions dontLogIfAttributesChangedOnly(List<String> attributes) {
    _dontLogIfAttributesChangedOnly = List.of(attributes);
    return this;
  }

  /// No activity when none of the logged attributes changed.
  LogOptions dontSubmitEmptyLogs() {
    _submitEmptyLogs = false;
    return this;
  }

  LogOptions submitEmptyLogs() {
    _submitEmptyLogs = true;
    return this;
  }

  LogOptions useLogName(String? logName) {
    _logName = logName;
    return this;
  }

  /// The description of an event's activity (the event name by default);
  /// an empty description logs nothing.
  LogOptions setDescriptionForEvent(
    String Function(String eventName) callback,
  ) {
    _descriptionForEvent = callback;
    return this;
  }

  /// These attributes as stored, without casts or accessors.
  LogOptions useAttributeRawValues(List<String> attributes) {
    _attributeRawValues = List.of(attributes);
    return this;
  }
}
