import 'request.dart';
import 'response.dart';

/// Continues the pipeline with [request] and yields the downstream response.
typedef Next = Future<Response> Function(Request request);

/// Onion-style middleware (BLUEPRINT_V2 §7.2.4).
abstract interface class Middleware {
  Future<Response> handle(Request request, Next next);
}

/// Middleware backed by a closure.
final class FunctionalMiddleware implements Middleware {
  const FunctionalMiddleware(this._handler);

  final Future<Response> Function(Request request, Next next) _handler;

  @override
  Future<Response> handle(Request request, Next next) =>
      _handler(request, next);
}

/// Runs a list of middleware around a core handler.
final class MiddlewarePipeline {
  const MiddlewarePipeline._();

  /// Executes [middleware] in order (first = outermost) around [core].
  static Future<Response> run(
    List<Middleware> middleware,
    Request request,
    Next core,
  ) {
    var next = core;
    for (final layer in middleware.reversed) {
      final downstream = next;
      next = (Request req) => layer.handle(req, downstream);
    }
    return next(request);
  }
}

/// Global middleware stack and alias registry configured via
/// `ApplicationBuilder.withMiddleware`.
final class MiddlewareRegistry {
  final List<Middleware> _global = <Middleware>[];
  final Map<String, Middleware> _aliases = <String, Middleware>{};

  /// Global middleware in execution order.
  List<Middleware> get global => List.unmodifiable(_global);

  /// Registered aliases.
  Map<String, Middleware> get aliases => Map.unmodifiable(_aliases);

  /// Appends [middleware] to the global stack.
  void use(List<Middleware> middleware) => _global.addAll(middleware);

  /// Inserts [middleware] at the front of the global stack.
  void prepend(Middleware middleware) => _global.insert(0, middleware);

  /// Removes every global middleware of type [T].
  void remove<T extends Middleware>() => _global.removeWhere((m) => m is T);

  /// Registers an alias usable in route definitions (`'auth'`).
  void alias(String name, Middleware middleware) => _aliases[name] = middleware;

  /// Resolves a route middleware entry: a [Middleware] instance or an alias.
  Middleware resolve(Object entry) {
    if (entry is Middleware) {
      return entry;
    }
    if (entry is String) {
      final middleware = _aliases[entry];
      if (middleware == null) {
        throw StateError(
          'Unknown middleware alias [$entry]. Register it with '
          'middleware.alias(\'$entry\', ...) in withMiddleware().',
        );
      }
      return middleware;
    }
    throw ArgumentError.value(
      entry,
      'entry',
      'Expected a Middleware instance or an alias String.',
    );
  }
}

/// Echoes the request id as `x-request-id` on every response.
final class RequestIdMiddleware implements Middleware {
  const RequestIdMiddleware();

  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    return response.withHeader('x-request-id', request.id);
  }
}
