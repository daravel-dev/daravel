import 'dart:async';

import 'request.dart';
import 'response.dart';

/// Continues the pipeline with [request] and yields the downstream response.
typedef Next = Future<Response> Function(Request request);

/// Builds a middleware from alias parameters (`'throttle:60,1'` → `[60, 1]`).
typedef MiddlewareFactory = Middleware Function(List<String> params);

/// Onion-style middleware (BLUEPRINT_V2 §7.2.4).
abstract interface class Middleware {
  Future<Response> handle(Request request, Next next);
}

/// Middleware with work to do after the response has been sent to the
/// client (Laravel's `terminate()`), such as flushing logs or metrics.
abstract interface class TerminableMiddleware implements Middleware {
  FutureOr<void> terminate(Request request, Response response);
}

/// Route middleware that runs before route bindings, as the entries above
/// `SubstituteBindings` in Laravel's `$middlewarePriority` (the same from 8
/// to 13): cookies, the session, authentication and rate limits. So a guest
/// gets 401 rather than a 404 that tells which records exist, and a binder
/// can use the authenticated user. The bindings run right after the last of
/// these on a route, or first when it has none.
abstract interface class RunsBeforeBindings implements Middleware {}

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
  ///
  /// With [rescue], an exception becomes a response at the layer that
  /// threw it, as `Illuminate\Pipeline\Pipeline::carry()`, so every outer
  /// middleware still finishes: the session is saved, cookies are
  /// encrypted, rate limit headers are added. A middleware that wraps
  /// `next` in a transaction therefore sees a response, not an exception.
  static Future<Response> run(
    List<Middleware> middleware,
    Request request,
    Next core, {
    Future<Response> Function(Object error, StackTrace stack, Request req)?
    rescue,
  }) {
    Next guarded(Next step) => rescue == null
        ? step
        : (Request req) async {
            try {
              return await step(req);
            } catch (error, stackTrace) {
              return rescue(error, stackTrace, req);
            }
          };
    var next = guarded(core);
    for (final layer in middleware.reversed) {
      final downstream = next;
      next = guarded((Request req) => layer.handle(req, downstream));
    }
    return next(request);
  }
}

/// Global middleware stack, aliases, groups and priority, configured via
/// `ApplicationBuilder.withMiddleware`.
///
/// Route middleware entries may be [Middleware] instances, alias names
/// (`'auth'`), parameterised aliases (`'throttle:60,1'`) or group names.
final class MiddlewareRegistry {
  final List<Middleware> _global = <Middleware>[];
  final Map<String, MiddlewareFactory> _aliases = <String, MiddlewareFactory>{};
  final Map<String, List<Object>> _groups = <String, List<Object>>{};
  List<Type> _priority = const <Type>[];

  /// Global middleware in execution order.
  List<Middleware> get global => List.unmodifiable(_global);

  List<Middleware>? _ordered;

  /// [global] sorted by priority; computed once, not per request.
  List<Middleware> get orderedGlobal =>
      _ordered ??= List.unmodifiable(applyPriority(_global));

  /// Registered alias names.
  Iterable<String> get aliases => _aliases.keys;

  /// Registered group names.
  Iterable<String> get groups => _groups.keys;

  /// The entries of group [name] (alias strings or middleware), or empty.
  List<Object> groupEntries(String name) =>
      List.unmodifiable(_groups[name] ?? const <Object>[]);

  /// Appends [middleware] to the global stack.
  void use(List<Middleware> middleware) {
    _global.addAll(middleware);
    _ordered = null;
  }

  /// Inserts [middleware] at the front of the global stack.
  void prepend(Middleware middleware) {
    _global.insert(0, middleware);
    _ordered = null;
  }

  /// Inserts [middleware] right after the first global middleware of type
  /// [T] (or at the front when none exists).
  void insertAfter<T extends Middleware>(Middleware middleware) {
    final index = _global.indexWhere((m) => m is T);
    _global.insert(index + 1, middleware);
    _ordered = null;
  }

  /// Removes every global middleware of type [T].
  void remove<T extends Middleware>() {
    _global.removeWhere((m) => m is T);
    _ordered = null;
  }

  /// Registers an alias resolving to a fixed instance (`'auth'`).
  void alias(String name, Middleware middleware) =>
      _aliases[name] = (_) => middleware;

  /// Registers an alias whose instance is built from parameters
  /// (`'throttle:60,1'` → `factory(['60', '1'])`).
  void aliasFactory(String name, MiddlewareFactory factory) =>
      _aliases[name] = factory;

  /// Registers a named group of entries (`'api'` → `[...]`).
  void group(String name, List<Object> entries) =>
      _groups[name] = List<Object>.of(entries);

  /// Orders resolved middleware by type: types listed here run first, in
  /// this order; other middleware keeps its relative order afterwards.
  void priority(List<Type> order) {
    _priority = List<Type>.of(order);
    _ordered = null;
  }

  /// Resolves a single entry (instance, alias, `alias:params` or group).
  List<Middleware> resolve(Object entry) {
    if (entry is Middleware) {
      return <Middleware>[entry];
    }
    if (entry is String) {
      final group = _groups[entry];
      if (group != null) {
        return <Middleware>[for (final item in group) ...resolve(item)];
      }
      final separator = entry.indexOf(':');
      final name = separator == -1 ? entry : entry.substring(0, separator);
      final params = separator == -1
          ? const <String>[]
          : entry
                .substring(separator + 1)
                .split(',')
                .map((p) => p.trim())
                .toList();
      final factory = _aliases[name];
      if (factory == null) {
        throw StateError(
          'Unknown middleware alias or group [$entry]. Register it with '
          "middleware.alias('$name', ...) or middleware.group('$name', [...]) "
          'in withMiddleware().',
        );
      }
      return <Middleware>[factory(params)];
    }
    throw ArgumentError.value(
      entry,
      'entry',
      'Expected a Middleware instance, an alias or a group name.',
    );
  }

  /// Resolves every entry and applies the configured [priority].
  List<Middleware> resolveAll(List<Object> entries) {
    final resolved = <Middleware>[
      for (final entry in entries) ...resolve(entry),
    ];
    return applyPriority(resolved);
  }

  /// Stable-sorts [middleware] so prioritised types come first.
  List<Middleware> applyPriority(List<Middleware> middleware) {
    if (_priority.isEmpty) {
      return middleware;
    }
    int rank(Middleware m) {
      final index = _priority.indexOf(m.runtimeType);
      return index == -1 ? _priority.length : index;
    }

    final indexed = middleware.indexed.toList()
      ..sort((a, b) {
        final byRank = rank(a.$2).compareTo(rank(b.$2));
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    return <Middleware>[for (final (_, m) in indexed) m];
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
