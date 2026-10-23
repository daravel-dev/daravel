import 'dart:async';

import '../foundation/container.dart';
import '../logging/logger.dart';
import '../routing/router.dart';
import 'exception_handler.dart';
import 'headers.dart';
import 'http_exceptions.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';

/// Orchestrates the request lifecycle (BLUEPRINT_V2 §5.4):
/// global middleware → routing → route middleware → handler → response
/// conversion, with exception rendering at both the route and global layers,
/// per-route timeouts and a terminate phase after the response is sent.
final class HttpKernel {
  HttpKernel({
    required this.router,
    required this.middleware,
    required this.exceptions,
    this.logger,
  });

  final Router router;
  final MiddlewareRegistry middleware;
  final ExceptionHandler exceptions;
  final Logger? logger;

  /// Default handler timeout applied when a route sets none (`null` = none).
  Duration? defaultTimeout;

  /// Handles a single request and always yields a response.
  Future<Response> handle(Request request) async {
    _bindLogContext(request);
    try {
      return await MiddlewarePipeline.run(
        middleware.applyPriority(middleware.global),
        request,
        _dispatch,
      );
    } catch (error, stackTrace) {
      return exceptions.handle(error, stackTrace, request);
    }
  }

  /// Runs `terminate()` of every terminable middleware that applied to the
  /// request plus the callbacks registered with [Request.defer]. Errors are
  /// reported and never propagate.
  Future<void> terminate(Request request, Response response) async {
    final layers = <Middleware>[
      ...middleware.global,
      ...?request.route?.resolvedMiddleware,
    ];
    for (final layer in layers) {
      if (layer is TerminableMiddleware) {
        try {
          await layer.terminate(request, response);
        } catch (error, stackTrace) {
          logger?.error(
            'terminate() of ${layer.runtimeType} failed',
            error: error,
            stackTrace: stackTrace,
            context: <String, Object?>{'request_id': request.id},
          );
        }
      }
    }
    for (final callback in request.takeDeferred()) {
      try {
        await callback();
      } catch (error, stackTrace) {
        logger?.error(
          'Deferred callback failed',
          error: error,
          stackTrace: stackTrace,
          context: <String, Object?>{'request_id': request.id},
        );
      }
    }
  }

  Future<Response> _dispatch(Request request) async {
    try {
      final match = router.lookup(request.method, request.path);
      if (match == null) {
        final allowed = router.allowedMethods(request.path);
        if (allowed.isEmpty) {
          throw NotFoundHttpException(
            'The route ${_label(request)} could not be found.',
          );
        }
        if (request.method == 'OPTIONS') {
          return Response(
            headers: Headers(<String, Object>{'allow': allowed.join(', ')}),
          );
        }
        throw MethodNotAllowedHttpException(
          allowed,
          'The ${request.method} method is not supported for route '
          '${_label(request)}. Supported methods: ${allowed.join(', ')}.',
        );
      }
      final route = match.value;
      request.bindRoute(route, <String, String>{
        for (final entry in route.defaultValues.entries)
          if (entry.value != null) entry.key: '${entry.value}',
        ...match.params,
      });
      await router.resolveBindings(request);
      final limit = route.bodyLimitBytes;
      if (limit != null) {
        request.maxBodyBytes = limit;
      }
      Future<Response> run() => MiddlewarePipeline.run(
        route.resolvedMiddleware,
        request,
        (req) async => toResponse(await route.handler(req), req),
      );
      final timeout = route.timeoutDuration ?? defaultTimeout;
      final response = timeout == null
          ? await run()
          : await run().timeout(
              timeout,
              onTimeout: () => throw ServiceUnavailableHttpException(
                'The request did not complete within ${timeout.inSeconds}s.',
              ),
            );
      return request.method == 'HEAD' ? response.withoutBody() : response;
    } catch (error, stackTrace) {
      return exceptions.handle(error, stackTrace, request);
    }
  }

  static void _bindLogContext(Request request) {
    try {
      final scope = Container.current.currentScope;
      if (scope != null && scope.get<LogContext>() == null) {
        scope.put<LogContext>(
          LogContext(<String, Object?>{'request_id': request.id}),
        );
      }
    } on StateError {
      // No container (bare kernel in unit tests).
    }
  }

  /// Converts a handler result into a [Response].
  static Response toResponse(Object? result, Request request) {
    switch (result) {
      case Response():
        return result;
      case Responsable():
        return result.toResponse(request);
      case null:
        return Response();
      case String():
        return Response.text(result);
      case Map<Object?, Object?>() ||
          List<Object?>() ||
          num() ||
          bool() ||
          JsonSerializable():
        return Response.json(result);
      default:
        throw StateError(
          'Route handler returned an unsupported value of type '
          '${result.runtimeType}. Return a Response, Responsable, Map, List, '
          'String, num, bool, JsonSerializable or null.',
        );
    }
  }

  static String _label(Request request) {
    final path = request.path;
    return path.startsWith('/') ? path.substring(1) : path;
  }
}
