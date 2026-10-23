import 'dart:async';

import '../logging/logger.dart';
import 'http_exceptions.dart';
import '../validation/validation_exception.dart';
import 'request.dart';
import 'response.dart';

/// Renders an exception of type [T] into a [Response], or returns `null` to
/// fall through to the next renderer.
typedef ExceptionRenderer<T extends Object> =
    Response? Function(T exception, Request request);

/// Reports (logs, forwards) an exception of type [T].
typedef ExceptionReporter<T extends Object> =
    FutureOr<void> Function(
      T exception,
      StackTrace stackTrace,
      Request request,
    );

final class _Renderer<T extends Object> {
  const _Renderer(this.render);

  final ExceptionRenderer<T> render;

  Response? tryRender(Object error, Request request) =>
      error is T ? render(error, request) : null;
}

final class _Reporter<T extends Object> {
  const _Reporter(this.report);

  final ExceptionReporter<T> report;

  FutureOr<void> tryReport(
    Object error,
    StackTrace stackTrace,
    Request request,
  ) => error is T ? report(error, stackTrace, request) : null;
}

/// Central exception → response mapping (ADR-009).
///
/// Default rendering produces Laravel-compatible JSON:
/// `{"message": "..."}` for [HttpException]s and
/// `{"message": "Server Error"}` for everything else (with `exception`,
/// `file`-less `trace` details when [debug] is enabled).
final class ExceptionHandler {
  ExceptionHandler({Logger? logger}) : _logger = logger;

  Logger? _logger;
  bool debug = false;

  final List<_Renderer<Object>> _renderers = <_Renderer<Object>>[];
  final List<_Reporter<Object>> _reporters = <_Reporter<Object>>[];
  final List<bool Function(Object error)> _dontReport =
      <bool Function(Object)>[];

  /// Attaches the logger used for default reporting.
  set logger(Logger logger) => _logger = logger;

  /// Registers a renderer for exceptions of type [T] (first match wins).
  void render<T extends Object>(ExceptionRenderer<T> renderer) =>
      _renderers.add(_Renderer<T>(renderer));

  /// Registers an additional reporter for exceptions of type [T].
  void report<T extends Object>(ExceptionReporter<T> reporter) =>
      _reporters.add(_Reporter<T>(reporter));

  /// Excludes exceptions of type [T] from default logging.
  void dontReport<T extends Object>() => _dontReport.add((error) => error is T);

  /// Reports then renders [error].
  Future<Response> handle(
    Object error,
    StackTrace stackTrace,
    Request request,
  ) async {
    await _report(error, stackTrace, request);
    for (final renderer in _renderers) {
      final response = renderer.tryRender(error, request);
      if (response != null) {
        return response;
      }
    }
    return _defaultRender(error, stackTrace, request);
  }

  Future<void> _report(
    Object error,
    StackTrace stackTrace,
    Request request,
  ) async {
    for (final reporter in _reporters) {
      await reporter.tryReport(error, stackTrace, request);
    }
    if (_dontReport.any((predicate) => predicate(error))) {
      return;
    }
    if (error is HttpException && error.status < 500) {
      return;
    }
    _logger?.error(
      'Unhandled exception while handling ${request.method} ${request.path}',
      error: error,
      stackTrace: stackTrace,
      context: <String, Object?>{'request_id': request.id},
    );
  }

  Response _defaultRender(
    Object error,
    StackTrace stackTrace,
    Request request,
  ) {
    if (error is ValidationException) {
      return Response.json(error.toJson(), status: 422);
    }
    if (error is HttpException) {
      return Response.json(
        <String, Object?>{'message': error.message},
        status: error.status,
        headers: error.headers,
      );
    }
    final payload = <String, Object?>{'message': 'Server Error'};
    if (debug) {
      payload['exception'] = error.runtimeType.toString();
      payload['error'] = error.toString();
      payload['trace'] = stackTrace.toString().trimRight().split('\n');
    }
    return Response.json(payload, status: 500);
  }
}
