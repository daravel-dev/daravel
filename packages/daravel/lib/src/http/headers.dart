import 'dart:io';

/// Case-insensitive, multi-value HTTP header collection.
final class Headers {
  /// Creates headers from a map whose values are `String` or `List<String>`.
  Headers([Map<String, Object>? initial]) {
    initial?.forEach((name, value) {
      if (value is List<String>) {
        for (final entry in value) {
          add(name, entry);
        }
      } else {
        set(name, '$value');
      }
    });
  }

  /// Copies the headers of a `dart:io` request/response.
  factory Headers.fromHttpHeaders(HttpHeaders headers) {
    final result = Headers();
    headers.forEach((name, values) {
      for (final value in values) {
        result.add(name, value);
      }
    });
    return result;
  }

  final Map<String, List<String>> _values = <String, List<String>>{};

  /// First value of [name], or `null`.
  String? operator [](String name) => first(name);

  /// First value of [name], or `null`.
  String? first(String name) {
    final values = _values[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }

  /// All values of [name] (empty when absent).
  List<String> all(String name) =>
      List.unmodifiable(_values[name.toLowerCase()] ?? const <String>[]);

  /// Whether [name] is present.
  bool has(String name) => _values.containsKey(name.toLowerCase());

  /// Replaces all values of [name] with [value].
  void set(String name, String value) =>
      _values[name.toLowerCase()] = <String>[value];

  /// Appends [value] to [name].
  void add(String name, String value) =>
      _values.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value);

  /// Removes [name].
  void remove(String name) => _values.remove(name.toLowerCase());

  /// Lower-cased header names.
  Iterable<String> get names => _values.keys;

  /// All entries (lower-cased name → values).
  Iterable<MapEntry<String, List<String>>> get entries => _values.entries;

  /// Whether no header is set.
  bool get isEmpty => _values.isEmpty;

  /// The `content-type` header, if any.
  String? get contentType => first('content-type');

  /// Deep copy.
  Headers copy() {
    final result = Headers();
    _values.forEach((name, values) => result._values[name] = List.of(values));
    return result;
  }

  /// Single-value projection (multiple values joined with `, `).
  Map<String, String> toSingleValueMap() => <String, String>{
    for (final entry in _values.entries) entry.key: entry.value.join(', '),
  };

  @override
  String toString() => _values.toString();
}
