import 'dart:async';

import '../foundation/container.dart';
import '../logging/logger.dart';
import '../routing/route_entry.dart';
import '../routing/router.dart';
import '../validation/form_request.dart';
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

  final _Deadlines _deadlines = _Deadlines();

  /// Handles a single request and always yields a response.
  Future<Response> handle(Request request) async {
    _bindLogContext(request);
    try {
      return await MiddlewarePipeline.run(
        middleware.orderedGlobal,
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
      // The same order as the request went through them.
      ...middleware.orderedGlobal,
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
      // Skipping empty awaits keeps the per-request path short.
      if (router.hasBindings) {
        await router.resolveBindings(request);
      }
      final limit = route.bodyLimitBytes;
      if (limit != null) {
        request.maxBodyBytes = limit;
      }
      Future<Response> run() => MiddlewarePipeline.run(
        route.resolvedMiddleware,
        request,
        (req) async {
          if (route.formRequest != null || route.declaredRules != null) {
            await _validateDeclared(route, req);
          }
          return toResponse(await route.handler(req), req);
        },
      );
      final timeout = route.timeoutDuration ?? defaultTimeout;
      final response = timeout == null
          ? await run()
          : await _deadlines.guard(run(), timeout);
      return request.method == 'HEAD' ? response.withoutBody() : response;
    } catch (error, stackTrace) {
      return exceptions.handle(error, stackTrace, request);
    }
  }

  /// Runs the validation declared with `.validates()` / `.rules()` and keeps
  /// the result for `request.validated()`.
  static Future<void> _validateDeclared(
    RouteEntry route,
    Request request,
  ) async {
    final form = route.formRequest;
    final rules = route.declaredRules;
    if (form != null) {
      request.attributes[Request.validatedAttribute] = await FormRequest.run(
        form,
        request,
      );
    } else if (rules != null) {
      request.attributes[Request.validatedAttribute] = await request.validate(
        rules,
      );
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
    // Laravel's Request::path(): trimmed of slashes, '/' for the root.
    final trimmed = request.path.replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? '/' : trimmed;
  }
}

/// Request timeouts without a timer per request.
///
/// A `Future.timeout` creates and cancels a timer for every request, and
/// cancelling the earliest timer makes the VM reschedule its wake-up: at
/// thousands of requests per second that cost about 15% of throughput.
/// Long timeouts (the 30 s default) are instead tracked in one set and
/// checked once a second by a single timer, so they fire within a second of
/// their deadline. Short timeouts keep a precise timer.
final class _Deadlines {
  static const Duration _coarseFrom = Duration(seconds: 2);
  static const Duration _interval = Duration(seconds: 1);
  static final Stopwatch _clock = Stopwatch()..start();

  final Set<_Deadline> _pending = <_Deadline>{};
  Timer? _sweeper;

  Future<Response> guard(Future<Response> work, Duration timeout) {
    if (timeout < _coarseFrom) {
      return work.timeout(timeout, onTimeout: () => throw _timedOut(timeout));
    }
    final deadline = _Deadline(
      _clock.elapsedMicroseconds + timeout.inMicroseconds,
      timeout,
    );
    _pending.add(deadline);
    _sweeper ??= Zone.root.run(() => Timer.periodic(_interval, _sweep));
    work.then(
      (response) {
        if (_pending.remove(deadline)) {
          deadline.result.complete(response);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_pending.remove(deadline)) {
          deadline.result.completeError(error, stackTrace);
        }
      },
    );
    return deadline.result.future;
  }

  void _sweep(Timer timer) {
    if (_pending.isEmpty) {
      timer.cancel();
      _sweeper = null;
      return;
    }
    final now = _clock.elapsedMicroseconds;
    final expired = [
      for (final deadline in _pending)
        if (deadline.at <= now) deadline,
    ];
    for (final deadline in expired) {
      _pending.remove(deadline);
      deadline.result.completeError(
        _timedOut(deadline.timeout),
        StackTrace.current,
      );
    }
  }

  static ServiceUnavailableHttpException _timedOut(Duration timeout) =>
      ServiceUnavailableHttpException(
        'The request did not complete within ${timeout.inSeconds}s.',
      );
}

final class _Deadline {
  _Deadline(this.at, this.timeout);

  /// Microseconds on [_Deadlines._clock].
  final int at;
  final Duration timeout;
  final Completer<Response> result = Completer<Response>();
}
