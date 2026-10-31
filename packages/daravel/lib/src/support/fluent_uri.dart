import '../http/request.dart';
import '../http/response.dart';

/// `Illuminate\Support\Uri`: an immutable URI to read and change one part at
/// a time, which `dart:core`'s `Uri.replace` makes awkward for queries.
///
/// ```dart
/// DaravelUri.of(request.url).withQuery({'page': 2}).withoutQuery('sort');
/// ```
///
/// Queries read and write like PHP's: `a[b]=1` is a map, and values are
/// escaped as `http_build_query` with RFC 3986 does, brackets included.
final class DaravelUri {
  DaravelUri._(this.raw);

  factory DaravelUri.of(Object uri) =>
      DaravelUri._(uri is Uri ? uri : Uri.parse('$uri'));

  /// The `dart:core` value.
  final Uri raw;

  String? get scheme => raw.scheme.isEmpty ? null : raw.scheme;
  String? get host => raw.host.isEmpty ? null : raw.host;
  int? get port => raw.hasPort ? raw.port : null;
  String? get fragment => raw.hasFragment ? raw.fragment : null;

  String? get user =>
      raw.userInfo.isEmpty ? null : raw.userInfo.split(':').first;

  /// The path without its outer slashes; `/` for the root.
  String get path {
    final trimmed = raw.path.replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? '/' : trimmed;
  }

  List<String> get pathSegments =>
      path == '/' ? const <String>[] : path.split('/');

  /// The query as PHP reads it.
  Map<String, Object?> get query => parseQueryString(raw.query);

  bool get isEmpty => '$raw'.trim().isEmpty;
  bool get isNotEmpty => !isEmpty;

  DaravelUri _rebuild({
    String? scheme,
    String? host,
    Object? port = _keep,
    String? rawPath,
    Object? rawQuery = _keep,
    Object? fragment = _keep,
  }) {
    final keptQuery = raw.hasQuery ? raw.query : null;
    return DaravelUri._(
      Uri(
        scheme: scheme ?? this.scheme,
        userInfo: raw.userInfo.isEmpty ? null : raw.userInfo,
        host: host ?? this.host,
        port: identical(port, _keep) ? this.port : port as int?,
        path: rawPath ?? raw.path,
        query: identical(rawQuery, _keep) ? keptQuery : rawQuery as String?,
        fragment: identical(fragment, _keep)
            ? this.fragment
            : fragment as String?,
      ),
    );
  }

  DaravelUri withScheme(String scheme) => _rebuild(scheme: scheme);
  DaravelUri withHost(String host) => _rebuild(host: host);
  DaravelUri withPort(int? port) => _rebuild(port: port);
  DaravelUri withPath(String path) =>
      _rebuild(rawPath: path.startsWith('/') ? path : '/$path');
  DaravelUri withFragment(String fragment) => _rebuild(fragment: fragment);
  DaravelUri withoutFragment() => _rebuild(fragment: null);

  /// Sets [values] on the query; dots reach into it, as `Arr::set`. With
  /// [merge] off, they are the whole query.
  DaravelUri withQuery(Map<String, Object?> values, {bool merge = true}) {
    final result = merge ? _deepCopy(query) : <String, Object?>{};
    for (final MapEntry(:key, :value) in values.entries) {
      _set(result, key.split('.'), value);
    }
    final encoded = _encode(result);
    return _rebuild(rawQuery: encoded.isEmpty ? null : encoded);
  }

  /// Only the [values] whose keys the query does not have.
  DaravelUri withQueryIfMissing(Map<String, Object?> values) {
    final current = query;
    return withQuery({
      for (final MapEntry(:key, :value) in values.entries)
        if (!current.containsKey(key)) key: value,
    });
  }

  /// Adds [value], or a list of them, to the list at [key]. A value already
  /// in the list stays once.
  DaravelUri pushOntoQuery(String key, Object? value) {
    final current = query[key];
    final added = value is List ? value : [value];
    return withQuery({
      key: switch (current) {
        final List<Object?> list => {...list, ...added}.toList(),
        null => added,
        final other => [other, ...added],
      },
    });
  }

  /// Removes a key, or a list of them.
  DaravelUri withoutQuery(Object keys) {
    final names = keys is List ? keys.cast<String>() : [keys as String];
    return replaceQuery({
      for (final MapEntry(:key, :value) in query.entries)
        if (!names.contains(key)) key: value,
    });
  }

  DaravelUri replaceQuery(Map<String, Object?> values) =>
      withQuery(values, merge: false);

  /// `redirect()->to()` for this URI.
  Response redirect({int status = 302}) =>
      Response.redirect('$this', status: status);

  /// This URI with its query readable.
  String decode() {
    final text = '$this';
    return raw.query.isEmpty
        ? text
        : text.replaceFirst(raw.query, Uri.decodeComponent(raw.query));
  }

  /// The URI, for JSON.
  String toJson() => '$this';

  @override
  String toString() => '$raw';

  @override
  bool operator ==(Object other) => other is DaravelUri && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;
}

const Object _keep = Object();

Map<String, Object?> _deepCopy(Map<String, Object?> source) => {
  for (final MapEntry(:key, :value) in source.entries)
    key: value is Map<String, Object?> ? _deepCopy(value) : value,
};

void _set(Map<String, Object?> target, List<String> path, Object? value) {
  if (path.length == 1) {
    target[path.first] = value;
    return;
  }
  final next = target[path.first];
  final child = next is Map<String, Object?> ? next : <String, Object?>{};
  target[path.first] = child;
  _set(child, path.sublist(1), value);
}

/// `http_build_query(..., PHP_QUERY_RFC3986)`: `null` leaves a key out, and
/// booleans are 1 and 0.
String _encode(Map<String, Object?> values) {
  final pairs = <String>[];
  void add(String key, Object? value) {
    switch (value) {
      case null:
        return;
      case final Map<Object?, Object?> map:
        for (final MapEntry(key: child, :value) in map.entries) {
          add('$key[$child]', value);
        }
      case final List<Object?> list:
        for (final (index, item) in list.indexed) {
          add('$key[$index]', item);
        }
      case final bool flag:
        pairs.add('${Uri.encodeComponent(key)}=${flag ? 1 : 0}');
      default:
        pairs.add(
          '${Uri.encodeComponent(key)}=${Uri.encodeComponent('$value')}',
        );
    }
  }

  values.forEach(add);
  return pairs.join('&');
}
