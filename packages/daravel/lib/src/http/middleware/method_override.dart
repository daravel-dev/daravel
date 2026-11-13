import 'dart:async';

import '../../routing/route_entry.dart';
import '../../routing/router.dart';
import '../http_exceptions.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// HTML forms and multipart uploads can only POST: `_method` or the
/// `X-HTTP-Method-Override` header names the real verb, as Symfony's
/// `Request::getMethod()` reads them (the header first, then the body, then
/// the query string).
///
/// Only form bodies are read, so JSON and raw uploads stay untouched
/// (Laravel also reads `_method` from a JSON body). Symfony takes any verb
/// but GET, HEAD, CONNECT and TRACE; this takes the three that forms need,
/// and ignores the others.
///
/// It runs before routing, so it reads a body only where that can change
/// the route: when [router] is given and the path has a `PUT`, `PATCH` or
/// `DELETE` route. Elsewhere the body is left unread (a `_method` in the
/// query string still applies). The body is then read under the loosest
/// body limit and timeout of the routes it may go to (that path's `POST`
/// route and those candidates), so no request a route accepts is refused
/// before it is known which; the kernel checks the matched route's own
/// limit against what was read once it is routed.
final class MethodOverrideMiddleware implements Middleware {
  /// Reads `_method` from a `POST` form, as Laravel does for HTML forms.
  ///
  /// [keepRawBody] (set by `withUpstream`) keeps a form's bytes before they
  /// are parsed, so a request no route matches still reaches the upstream
  /// with its body: parsing a multipart body consumes the stream. Such a
  /// body is then buffered in memory in full (up to `HTTP_MAX_BODY`); an
  /// application that proxies large uploads sets
  /// `middleware.methodOverride = false` so they stream through unread.
  ///
  /// [router] (the application's, given lazily) decides whether a body is
  /// read at all; without it every form `POST` is read, as before.
  /// [defaultTimeout] is the kernel's, for routes without their own.
  const MethodOverrideMiddleware({
    this.keepRawBody = false,
    this.router,
    this.defaultTimeout,
  });

  /// The methods a form may ask for.
  static const Set<String> allowed = {'PUT', 'PATCH', 'DELETE'};

  /// Whether a form's raw bytes are kept for `Request.bodyStream()`.
  final bool keepRawBody;

  /// The routes, to find whether a path can be overridden at all.
  final Router Function()? router;

  /// The handler timeout of a route without its own.
  final Duration? Function()? defaultTimeout;

  @override
  Future<Response> handle(Request request, Next next) async {
    if (request.method == 'POST') {
      final target = await _target(request);
      if (allowed.contains(target)) {
        request.overrideMethod(target!);
      }
    }
    return next(request);
  }

  Future<String?> _target(Request request) async {
    final header = request.headers.first('x-http-method-override');
    if (header != null && header.isNotEmpty) {
      return header.toUpperCase();
    }
    final query = switch (request.queryInput['_method']) {
      final String method => method.toUpperCase(),
      _ => null,
    };
    final contentType = (request.headers.contentType ?? '').toLowerCase();
    final isForm =
        contentType.contains('application/x-www-form-urlencoded') ||
        contentType.contains('multipart/form-data');
    if (!isForm) {
      return query;
    }
    final routes = router?.call();
    final List<RouteEntry> reachable;
    if (routes == null) {
      reachable = const [];
    } else {
      final candidates = [
        for (final method in allowed)
          ?routes.lookup(method, request.path, host: request.host)?.value,
      ];
      if (candidates.isEmpty) {
        // Nothing here a `_method` could reach: the body stays unread.
        return query;
      }
      reachable = [
        ...candidates,
        ?routes.lookup('POST', request.path, host: request.host)?.value,
      ];
    }
    final before = request.maxBodyBytes;
    try {
      final timeout = _loosest(request, reachable);
      final read = _read(request);
      final body = timeout == null
          ? await read
          : await read.timeout(
              timeout,
              onTimeout: () {
                final error = ServiceUnavailableHttpException(
                  'The request did not complete within '
                  '${timeout.inSeconds}s.',
                );
                request.abortBodyRead(error);
                throw error;
              },
            );
      final value = body is Map ? body['_method'] : null;
      return switch (value) {
        final String method => method.toUpperCase(),
        _ => query,
      };
    } finally {
      // The route's own limit applies once routed (the kernel checks what
      // was read against it).
      request.maxBodyBytes = before;
    }
  }

  Future<Object?> _read(Request request) async {
    if (keepRawBody) {
      // Cached first: body() and bodyStream() then read these bytes.
      await request.bytes();
    }
    return request.body();
  }

  /// Sets the request's body limit to the loosest of [routes] (each one's
  /// `bodyLimit`, or the limit the request has now), and returns their
  /// loosest timeout, or null when one has none. No [routes]: as they are.
  Duration? _loosest(Request request, List<RouteEntry> routes) {
    if (routes.isEmpty) {
      return null;
    }
    final current = request.maxBodyBytes;
    int? limit = 0;
    Duration? timeout = Duration.zero;
    for (final route in routes) {
      final bytes = route.bodyLimitBytes ?? current;
      limit = limit == null || bytes == null
          ? null
          : (bytes > limit ? bytes : limit);
      final time = route.timeoutDuration ?? defaultTimeout?.call();
      timeout = timeout == null || time == null
          ? null
          : (time > timeout ? time : timeout);
    }
    request.maxBodyBytes = limit;
    return timeout;
  }
}
