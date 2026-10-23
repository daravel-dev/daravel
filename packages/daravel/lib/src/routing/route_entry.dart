import 'dart:async';

import '../http/middleware.dart';
import '../http/request.dart';
import 'radix_tree.dart';

/// A route handler. May return a `Response`, a `Responsable`, a JSON-able
/// value (`Map`, `List`, `num`, `bool`, `JsonSerializable`), a `String`
/// (text) or `null` (empty 200).
typedef Handler = FutureOr<Object?> Function(Request request);

/// A registered route with fluent configuration (BLUEPRINT_V2 §7.3.2).
final class RouteEntry {
  RouteEntry({
    required this.methods,
    required this.path,
    required this.handler,
    List<Object> middleware = const <Object>[],
    String namePrefix = '',
  }) : _middleware = List<Object>.of(middleware),
       _namePrefix = namePrefix;

  /// Upper-cased HTTP methods served by this route.
  final List<String> methods;

  /// Normalized path (`/api/users/{id}`).
  final String path;

  /// The handler.
  final Handler handler;

  final List<Object> _middleware;
  final String _namePrefix;
  String? _name;
  List<Middleware> _resolved = const <Middleware>[];
  Duration? _timeout;
  int? _bodyLimitBytes;

  /// Per-route handler timeout (overrides the server default).
  Duration? get timeoutDuration => _timeout;

  /// Per-route body limit in bytes (overrides `BodyLimitsMiddleware`).
  int? get bodyLimitBytes => _bodyLimitBytes;

  /// Sets a handler timeout; the kernel answers `503` when exceeded.
  RouteEntry timeout(Duration duration) {
    _timeout = duration;
    return this;
  }

  /// Sets the maximum body size accepted by this route.
  RouteEntry bodyLimit(int bytes) {
    _bodyLimitBytes = bytes;
    return this;
  }

  /// The route name (including any group prefix), if set.
  String? get routeName => _name;

  /// Middleware entries as registered (instances or aliases).
  List<Object> get middlewareEntries => List.unmodifiable(_middleware);

  /// Middleware resolved at compile time.
  List<Middleware> get resolvedMiddleware => _resolved;

  /// Parameter names in order of appearance.
  List<String> get parameterNames => <String>[
    for (final segment in RadixTree.splitPath(path))
      ?RadixTree.paramName(segment) ?? RadixTree.wildcardName(segment),
  ];

  /// Assigns a name (prefixed by the enclosing group name prefix).
  RouteEntry name(String name) {
    _name = '$_namePrefix$name';
    return this;
  }

  /// Appends route middleware (instances or aliases).
  RouteEntry middleware(List<Object> entries) {
    _middleware.addAll(entries);
    return this;
  }

  /// Removes middleware of type [T] from this route.
  RouteEntry withoutMiddleware<T extends Middleware>() {
    _middleware.removeWhere((entry) => entry is T);
    return this;
  }

  /// Resolves aliases into instances. Called by `Router.compile`.
  void resolveMiddleware(MiddlewareRegistry registry) {
    _resolved = List.unmodifiable(registry.resolveAll(_middleware));
  }

  @override
  String toString() =>
      'RouteEntry(${methods.join('|')} $path'
      '${_name == null ? '' : ' name=$_name'})';
}
