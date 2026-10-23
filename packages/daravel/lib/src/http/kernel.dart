import '../routing/router.dart';
import 'exception_handler.dart';
import 'headers.dart';
import 'http_exceptions.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';

/// Orchestrates the request lifecycle (BLUEPRINT_V2 §5.4):
/// global middleware → routing → route middleware → handler → response
/// conversion, with exception rendering at both the route and global layers.
final class HttpKernel {
  HttpKernel({
    required this.router,
    required this.middleware,
    required this.exceptions,
  });

  final Router router;
  final MiddlewareRegistry middleware;
  final ExceptionHandler exceptions;

  /// Handles a single request and always yields a response.
  Future<Response> handle(Request request) async {
    try {
      return await MiddlewarePipeline.run(
        middleware.global,
        request,
        _dispatch,
      );
    } catch (error, stackTrace) {
      return exceptions.handle(error, stackTrace, request);
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
          return Response(headers: Headers(_allowHeaders(allowed)));
        }
        throw MethodNotAllowedHttpException(
          allowed,
          'The ${request.method} method is not supported for route '
          '${_label(request)}. Supported methods: ${allowed.join(', ')}.',
        );
      }
      final route = match.value;
      request.bindRoute(route, match.params);
      final response = await MiddlewarePipeline.run(
        route.resolvedMiddleware,
        request,
        (req) async => toResponse(await route.handler(req), req),
      );
      return request.method == 'HEAD' ? response.withoutBody() : response;
    } catch (error, stackTrace) {
      return exceptions.handle(error, stackTrace, request);
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

  static Map<String, Object> _allowHeaders(List<String> allowed) =>
      <String, Object>{'allow': allowed.join(', ')};
}
