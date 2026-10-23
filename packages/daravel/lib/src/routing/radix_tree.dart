/// Result of a successful [RadixTree.lookup].
final class RouteMatch<T extends Object> {
  const RouteMatch(this.value, this.params);

  final T value;
  final Map<String, String> params;
}

final class _Node<T extends Object> {
  final Map<String, _Node<T>> statics = <String, _Node<T>>{};
  _Node<T>? param;
  _Node<T>? wildcard;
  String? name;
  T? value;
}

/// Segment-based route tree with static > parameter > wildcard priority and
/// backtracking (BLUEPRINT_V2 §7.3.1). Prefix compression of static segments
/// is scheduled for slice S3; the matching semantics are already final.
///
/// Supported syntaxes: `/users/{id}`, `/users/:id`, `/files/{path*}`,
/// `/files/*path`. Wildcards must be the last segment.
final class RadixTree<T extends Object> {
  final _Node<T> _root = _Node<T>();

  /// Registers [value] for [path]. Registering the same path twice replaces
  /// the previous value (Laravel parity: the last definition wins).
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
        final existing = node.param;
        if (existing != null && existing.name != param) {
          throw ArgumentError(
            'Conflicting parameter names "${existing.name}" and "$param" at '
            'the same position in route "$path".',
          );
        }
        node = node.param ??= (_Node<T>()..name = param);
        continue;
      }
      node = node.statics.putIfAbsent(segment, _Node<T>.new);
    }
    node.value = value;
  }

  /// Finds the best match for [path], or `null`.
  RouteMatch<T>? lookup(String path) {
    final params = <String, String>{};
    final node = _match(_root, splitPath(path), 0, params);
    if (node == null) {
      return null;
    }
    return RouteMatch<T>(node.value!, params);
  }

  _Node<T>? _match(
    _Node<T> node,
    List<String> segments,
    int index,
    Map<String, String> params,
  ) {
    if (index == segments.length) {
      return node.value != null ? node : null;
    }
    final segment = segments[index];

    final staticChild = node.statics[segment];
    if (staticChild != null) {
      final found = _match(staticChild, segments, index + 1, params);
      if (found != null) {
        return found;
      }
    }

    final paramChild = node.param;
    if (paramChild != null && segment.isNotEmpty) {
      final name = paramChild.name!;
      final previous = params[name];
      params[name] = _decode(segment);
      final found = _match(paramChild, segments, index + 1, params);
      if (found != null) {
        return found;
      }
      if (previous == null) {
        params.remove(name);
      } else {
        params[name] = previous;
      }
    }

    final wildcardChild = node.wildcard;
    if (wildcardChild != null && wildcardChild.value != null) {
      params[wildcardChild.name!] = segments
          .sublist(index)
          .map(_decode)
          .join('/');
      return wildcardChild;
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
  static String? paramName(String segment) {
    if (segment.length > 2 &&
        segment.startsWith('{') &&
        segment.endsWith('}')) {
      final inner = segment.substring(1, segment.length - 1);
      return inner.endsWith('*') ? null : inner;
    }
    if (segment.length > 1 && segment.startsWith(':')) {
      return segment.substring(1);
    }
    return null;
  }

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
