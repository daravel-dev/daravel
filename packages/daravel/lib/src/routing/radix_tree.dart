/// Result of a successful [RadixTree.lookup].
final class RouteMatch<T extends Object> {
  const RouteMatch(this.value, this.params);

  final T value;
  final Map<String, String> params;
}

/// Decides whether [value] accepts the captured [params] (route constraints).
typedef MatchPredicate<T extends Object> = bool Function(
  T value,
  Map<String, String> params,
);

final class _Node<T extends Object> {
  final Map<String, _Node<T>> statics = <String, _Node<T>>{};
  final List<_Node<T>> params = <_Node<T>>[];
  _Node<T>? wildcard;
  String? name;
  final List<T> values = <T>[];
}

/// Segment-based route tree with static > parameter > wildcard priority and
/// backtracking (BLUEPRINT_V2 §7.3.1).
///
/// A node may hold several values (routes registered for the same path, e.g.
/// `/posts/{id}` constrained to digits and `/posts/{slug}` for the rest) and
/// several parameter children with different names; [lookup] visits them in
/// registration order and returns the first one accepted by the predicate,
/// which gives Laravel's "first matching route wins" semantics with
/// constraints.
///
/// Supported syntaxes: `/users/{id}`, `/users/:id`, `/files/{path*}`,
/// `/files/*path`. Wildcards must be the last segment.
final class RadixTree<T extends Object> {
  final _Node<T> _root = _Node<T>();

  static bool _acceptAll<T extends Object>(T value, Map<String, String> p) =>
      true;

  /// Registers [value] for [path].
  void insert(String path, T value) {
    final segments = splitPath(path);
    var node = _root;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final wildcard = wildcardName(segment);
      if (wildcard != null) {
        if (i != segments.length - 1) {
          throw ArgumentError(
            'Wildcard segment must be last in route "$path".',
          );
        }
        final existing = node.wildcard;
        if (existing != null && existing.name != wildcard) {
          throw ArgumentError(
            'Conflicting wildcard names "${existing.name}" and "$wildcard" '
            'in route "$path".',
          );
        }
        node = node.wildcard ??= (_Node<T>()..name = wildcard);
        continue;
      }
      final param = paramName(segment);
      if (param != null) {
        _Node<T>? child;
        for (final candidate in node.params) {
          if (candidate.name == param) {
            child = candidate;
            break;
          }
        }
        if (child == null) {
          child = _Node<T>()..name = param;
          node.params.add(child);
        }
        node = child;
        continue;
      }
      node = node.statics.putIfAbsent(segment, _Node<T>.new);
    }
    node.values.add(value);
  }

  /// Finds the first route matching [path] whose [accept] predicate passes.
  RouteMatch<T>? lookup(String path, {MatchPredicate<T>? accept}) => _match(
    _root,
    splitPath(path),
    0,
    <String, String>{},
    accept ?? _acceptAll,
  );

  RouteMatch<T>? _match(
    _Node<T> node,
    List<String> segments,
    int index,
    Map<String, String> params,
    MatchPredicate<T> accept,
  ) {
    if (index == segments.length) {
      return _select(node, params, accept);
    }
    final segment = segments[index];

    final staticChild = node.statics[segment];
    if (staticChild != null) {
      final found = _match(staticChild, segments, index + 1, params, accept);
      if (found != null) {
        return found;
      }
    }

    if (segment.isNotEmpty) {
      for (final paramChild in node.params) {
        final name = paramChild.name!;
        final previous = params[name];
        params[name] = _decode(segment);
        final found = _match(paramChild, segments, index + 1, params, accept);
        if (found != null) {
          return found;
        }
        if (previous == null) {
          params.remove(name);
        } else {
          params[name] = previous;
        }
      }
    }

    final wildcardChild = node.wildcard;
    if (wildcardChild != null) {
      final name = wildcardChild.name!;
      params[name] = segments.sublist(index).map(_decode).join('/');
      final found = _select(wildcardChild, params, accept);
      if (found != null) {
        return found;
      }
      params.remove(name);
    }
    return null;
  }

  RouteMatch<T>? _select(
    _Node<T> node,
    Map<String, String> params,
    MatchPredicate<T> accept,
  ) {
    for (final value in node.values) {
      if (accept(value, params)) {
        return RouteMatch<T>(value, Map<String, String>.of(params));
      }
    }
    return null;
  }

  static String _decode(String segment) {
    try {
      return Uri.decodeComponent(segment);
    } on ArgumentError {
      return segment;
    }
  }

  /// Splits a path into non-empty segments (`/a//b/` → `[a, b]`).
  static List<String> splitPath(String path) =>
      path.split('/').where((segment) => segment.isNotEmpty).toList();

  /// Returns the parameter name for `{id}` / `:id` segments, else `null`.
  /// An optional marker (`{id?}`) is stripped; see [isOptional].
  static String? paramName(String segment) {
    if (segment.length > 2 &&
        segment.startsWith('{') &&
        segment.endsWith('}')) {
      var inner = segment.substring(1, segment.length - 1);
      if (inner.endsWith('*')) {
        return null;
      }
      if (inner.endsWith('?')) {
        inner = inner.substring(0, inner.length - 1);
      }
      // `{post:slug}`: the column belongs to the binding, not the name.
      final colon = inner.indexOf(':');
      return colon == -1 ? inner : inner.substring(0, colon);
    }
    if (segment.length > 1 && segment.startsWith(':')) {
      return segment.substring(1);
    }
    return null;
  }

  /// Whether [segment] is an optional parameter (`{slug?}`).
  static bool isOptional(String segment) =>
      segment.length > 3 && segment.startsWith('{') && segment.endsWith('?}');

  /// Returns the wildcard name for `{path*}` / `*path` segments, else `null`.
  static String? wildcardName(String segment) {
    if (segment.length > 3 &&
        segment.startsWith('{') &&
        segment.endsWith('*}')) {
      return segment.substring(1, segment.length - 2);
    }
    if (segment.length > 1 && segment.startsWith('*')) {
      return segment.substring(1);
    }
    return null;
  }
}
