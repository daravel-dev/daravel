import '../http/middleware.dart';
import 'radix_tree.dart';
import 'route_entry.dart';

final class _GroupAttributes {
  const _GroupAttributes({
    this.prefix = '',
    this.namePrefix = '',
    this.middleware = const <Object>[],
  });

  final String prefix;
  final String namePrefix;
  final List<Object> middleware;
}

/// Fluent router (BLUEPRINT_V2 §7.3.2). Routes are registered during boot and
/// compiled once into per-method [RadixTree]s.
final class Router {
  final List<RouteEntry> _routes = <RouteEntry>[];
  final Map<String, RadixTree<RouteEntry>> _trees =
      <String, RadixTree<RouteEntry>>{};
  final List<_GroupAttributes> _groups = <_GroupAttributes>[];
  bool _compiled = false;

  static const List<String> _allMethods = <String>[
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'OPTIONS',
  ];

  /// Whether [compile] has run.
  bool get isCompiled => _compiled;

  /// All registered routes in registration order.
  List<RouteEntry> get routes => List.unmodifiable(_routes);

  RouteEntry get(String path, Handler handler) =>
      match(const <String>['GET', 'HEAD'], path, handler);

  RouteEntry post(String path, Handler handler) =>
      match(const <String>['POST'], path, handler);

  RouteEntry put(String path, Handler handler) =>
      match(const <String>['PUT'], path, handler);

  RouteEntry patch(String path, Handler handler) =>
      match(const <String>['PATCH'], path, handler);

  RouteEntry delete(String path, Handler handler) =>
      match(const <String>['DELETE'], path, handler);

  RouteEntry options(String path, Handler handler) =>
      match(const <String>['OPTIONS'], path, handler);

  /// Registers [handler] for every standard method.
  RouteEntry any(String path, Handler handler) =>
      match(_allMethods, path, handler);

  /// Registers [handler] for the given [methods].
  RouteEntry match(List<String> methods, String path, Handler handler) {
    _ensureNotCompiled();
    final attributes = _current;
    final entry = RouteEntry(
      methods: methods
          .map((method) => method.toUpperCase())
          .toList(growable: false),
      path: joinPaths(attributes.prefix, path),
      handler: handler,
      middleware: attributes.middleware,
      namePrefix: attributes.namePrefix,
    );
    _routes.add(entry);
    return entry;
  }

  /// Registers routes with stacked [prefix], [name] prefix and [middleware].
  void group(
    void Function(Router router) routes, {
    String prefix = '',
    String name = '',
    List<Object> middleware = const <Object>[],
  }) {
    _ensureNotCompiled();
    final parent = _current;
    _groups.add(
      _GroupAttributes(
        prefix: joinPaths(parent.prefix, prefix),
        namePrefix: '${parent.namePrefix}$name',
        middleware: <Object>[...parent.middleware, ...middleware],
      ),
    );
    try {
      routes(this);
    } finally {
      _groups.removeLast();
    }
  }

  /// Builds the lookup trees and resolves middleware aliases. Validates that
  /// route names are unique.
  void compile(MiddlewareRegistry registry) {
    _trees.clear();
    final names = <String>{};
    for (final route in _routes) {
      route.resolveMiddleware(registry);
      final name = route.routeName;
      if (name != null && !names.add(name)) {
        throw StateError('Duplicate route name [$name].');
      }
      for (final method in route.methods) {
        _trees
            .putIfAbsent(method, RadixTree<RouteEntry>.new)
            .insert(route.path, route);
      }
    }
    _compiled = true;
  }

  /// Looks up the route for [method] + [path]. `HEAD` falls back to `GET`.
  RouteMatch<RouteEntry>? lookup(String method, String path) {
    _ensureCompiled();
    final upper = method.toUpperCase();
    final direct = _trees[upper]?.lookup(path);
    if (direct != null) {
      return direct;
    }
    if (upper == 'HEAD') {
      return _trees['GET']?.lookup(path);
    }
    return null;
  }

  /// Methods that have a route for [path] (used for `405` / `OPTIONS`).
  List<String> allowedMethods(String path) {
    _ensureCompiled();
    final allowed = <String>{};
    for (final entry in _trees.entries) {
      if (entry.value.lookup(path) != null) {
        allowed.add(entry.key);
      }
    }
    if (allowed.contains('GET')) {
      allowed.add('HEAD');
    }
    final ordered = <String>[
      for (final method in _allMethods)
        if (allowed.contains(method)) method,
      for (final method in allowed)
        if (!_allMethods.contains(method)) method,
    ];
    return ordered;
  }

  /// Whether a route named [name] exists.
  bool has(String name) => _routes.any((route) => route.routeName == name);

  /// Generates a path for the named route, substituting [params] and
  /// appending [query].
  String url(
    String name, {
    Map<String, Object?> params = const <String, Object?>{},
    Map<String, Object?> query = const <String, Object?>{},
  }) {
    final route = _routes.firstWhere(
      (route) => route.routeName == name,
      orElse: () => throw ArgumentError('Route [$name] is not defined.'),
    );
    final segments = <String>[];
    for (final segment in RadixTree.splitPath(route.path)) {
      final paramName =
          RadixTree.paramName(segment) ?? RadixTree.wildcardName(segment);
      if (paramName == null) {
        segments.add(segment);
        continue;
      }
      final value = params[paramName];
      if (value == null) {
        throw ArgumentError(
          'Missing required parameter [$paramName] for route [$name].',
        );
      }
      final isWildcard = RadixTree.wildcardName(segment) != null;
      segments.add(
        isWildcard
            ? '$value'.split('/').map(Uri.encodeComponent).join('/')
            : Uri.encodeComponent('$value'),
      );
    }
    final path = '/${segments.join('/')}';
    if (query.isEmpty) {
      return path;
    }
    final queryString = Uri(
      queryParameters: <String, String>{
        for (final entry in query.entries)
          if (entry.value != null) entry.key: '${entry.value}',
      },
    ).query;
    return queryString.isEmpty ? path : '$path?$queryString';
  }

  /// Joins two path fragments into a normalized path (`/` for root).
  static String joinPaths(String base, String path) {
    final segments = <String>[
      ...RadixTree.splitPath(base),
      ...RadixTree.splitPath(path),
    ];
    return '/${segments.join('/')}';
  }

  _GroupAttributes get _current =>
      _groups.isEmpty ? const _GroupAttributes() : _groups.last;

  void _ensureNotCompiled() {
    if (_compiled) {
      throw StateError(
        'Routes cannot be registered after the router has been compiled.',
      );
    }
  }

  void _ensureCompiled() {
    if (!_compiled) {
      throw StateError('Router.compile() must run before matching routes.');
    }
  }
}
