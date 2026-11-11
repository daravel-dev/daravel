import '../http/uploaded_file.dart';
import 'rule.dart';
import 'rules.dart';
import 'typed_rules.dart';

/// Validated input with typed accessors (ADR-011). Only attributes that had
/// rules are included (Laravel `$request->validated()` parity).
extension type const ValidatedData(Map<String, Object?> _data)
    implements Object {
  /// Raw value at dot [path].
  Object? get(String path) => ValidationContext.dig(_data, path);

  /// Whether [path] exists.
  bool has(String path) => ValidationContext.exists(_data, path);

  /// The value at [path] as a string; throws when it is missing.
  String string(String path) =>
      _require<String>(path, (v) => v is String ? v : '$v');

  /// The uploaded file at [path] (validate it with `file`, `image` or
  /// `mimes`).
  UploadedFile file(String path) => _require<UploadedFile>(
    path,
    (v) => v is UploadedFile ? v : null,
    expected: 'file',
  );

  /// The value at [path] as a string, or null when missing or null.
  String? maybeString(String path) {
    final value = get(path);
    return value == null ? null : (value is String ? value : '$value');
  }

  /// The value at [path] as an int (`'42'` included); throws when missing
  /// or not an integer.
  int integer(String path) =>
      _require<int>(path, IntegerRule.asInt, expected: 'integer');

  /// The value at [path] as an int, or null.
  int? maybeInteger(String path) => IntegerRule.asInt(get(path));

  /// The value at [path] as a number; throws when missing or not numeric.
  num number(String path) =>
      _require<num>(path, NumericRule.asNum, expected: 'number');

  /// The value at [path] as a double; throws when missing or not numeric.
  double decimal(String path) => number(path).toDouble();

  /// The value at [path] as a bool (`1`, `'0'`, `'true'`... included);
  /// throws when missing or not a boolean.
  bool boolean(String path) =>
      _require<bool>(path, BooleanRule.asBool, expected: 'boolean');

  /// The value at [path] as a bool, or null.
  bool? maybeBoolean(String path) => BooleanRule.asBool(get(path));

  /// The value at [path] as a [DateTime]; throws when missing or not a
  /// date.
  DateTime dateTime(String path) =>
      _require<DateTime>(path, parseDate, expected: 'date');

  /// The value at [path] as a [DateTime], or null.
  DateTime? maybeDateTime(String path) => parseDate(get(path));

  /// The list at [path], its items cast to [T]; throws when missing.
  List<T> list<T>(String path) {
    final value = get(path);
    if (value is List<Object?>) {
      return value.cast<T>();
    }
    throw StateError('Validated attribute [$path] is not a list.');
  }

  /// The map at [path]; throws when missing.
  Map<String, Object?> map(String path) {
    final value = get(path);
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map<Object?, Object?>) {
      return value.map((k, v) => MapEntry('$k', v));
    }
    throw StateError('Validated attribute [$path] is not an object.');
  }

  /// A nested object as [ValidatedData].
  ValidatedData nested(String path) => ValidatedData(map(path));

  /// Subset with only [keys] (top level).
  Map<String, Object?> only(List<String> keys) => {
    for (final key in keys)
      if (_data.containsKey(key)) key: _data[key],
  };

  /// Everything except [keys] (top level).
  Map<String, Object?> except(List<String> keys) => {
    for (final entry in _data.entries)
      if (!keys.contains(entry.key)) entry.key: entry.value,
  };

  /// Mutable copy of the data.
  Map<String, Object?> toMap() => Map<String, Object?>.of(_data);

  /// The data as JSON, for `Response.json(request.validated())`.
  Map<String, Object?> toJson() => toMap();

  /// The value of [field] as its declared type [T], converted as the typed
  /// accessors do (`int` from `'42'`, `bool` from `'1'`, `DateTime` from a
  /// date string, ...). Null only when [T] is nullable and the value is
  /// missing or null.
  ///
  /// A value the rules let through but [T] cannot hold (a `Field<int>`
  /// whose rules do not include `integer`) is a [StateError] naming the
  /// field, the declared type and the value, so the mismatch between the
  /// field's type and its rules shows in development, not as a cast error.
  T field<T>(Field<T> field) {
    final raw = get(field);
    final nullable = null is T;
    if (raw == null) {
      if (nullable) {
        return null as T;
      }
      throw StateError(
        'Validated attribute [$field] (Field<$T>) is missing or null; '
        'declare it Field<$T?> or make it required.',
      );
    }
    final Object? converted = switch (_base<T>()) {
      _Kind.string => raw is String ? raw : null,
      _Kind.integer => IntegerRule.asInt(raw),
      _Kind.float => NumericRule.asNum(raw)?.toDouble(),
      _Kind.number => NumericRule.asNum(raw),
      _Kind.boolean => BooleanRule.asBool(raw),
      _Kind.dateTime => parseDate(raw),
      _Kind.data => switch (raw) {
        Map<String, Object?>() => ValidatedData(raw),
        Map<Object?, Object?>() => ValidatedData(
          raw.map((k, v) => MapEntry('$k', v)),
        ),
        _ => null,
      },
      _Kind.other => raw,
    };
    if (converted is T) {
      return converted;
    }
    throw StateError(
      'Validated attribute [$field] is declared Field<$T> but holds '
      '${raw is String ? '"$raw"' : raw} (${raw.runtimeType}); add the rule '
      'that guarantees $T, or change the field type.',
    );
  }

  static _Kind _base<T>() {
    bool isType<B>() => T == B || _typeOf<T>() == _typeOf<B?>();
    if (isType<String>()) return _Kind.string;
    if (isType<int>()) return _Kind.integer;
    if (isType<double>()) return _Kind.float;
    if (isType<num>()) return _Kind.number;
    if (isType<bool>()) return _Kind.boolean;
    if (isType<DateTime>()) return _Kind.dateTime;
    if (isType<ValidatedData>()) return _Kind.data;
    return _Kind.other;
  }

  T _require<T>(
    String path,
    T? Function(Object? value) convert, {
    String expected = 'string',
  }) {
    final raw = get(path);
    if (raw == null) {
      throw StateError('Validated attribute [$path] is missing.');
    }
    final converted = convert(raw);
    if (converted == null) {
      throw StateError('Validated attribute [$path] is not a valid $expected.');
    }
    return converted;
  }
}

/// The conversions of [ValidatedData.field].
enum _Kind { string, integer, float, number, boolean, dateTime, data, other }

Type _typeOf<T>() => T;
