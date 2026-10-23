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
    _resolved = List.unmodifiable(_middleware.map(registry.resolve));
  }

  @override
  String toString() =>
      'RouteEntry(${methods.join('|')} $path'
      '${_name == null ? '' : ' name=$_name'})';
}
