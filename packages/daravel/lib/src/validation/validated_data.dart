import '../http/uploaded_file.dart';
import 'rule.dart';
import 'rules.dart';

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
