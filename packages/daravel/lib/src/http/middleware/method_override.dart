import '../../routing/route_entry.dart';
import '../../routing/router.dart';
import '../body_limit_refusal.dart';
import '../http_exceptions.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// HTML forms and multipart uploads can only POST: `_method` or the
/// `X-HTTP-Method-Override` header names the real verb, as Symfony's
/// `Request::getMethod()` reads them.
///
/// Only form bodies are read, so JSON and raw uploads stay untouched. Symfony
/// takes any verb but GET, HEAD, CONNECT and TRACE; this takes the three that
/// forms need.
///
/// A form whose declared length is over the limit of `BodyLimitsMiddleware`
/// is read only when the `bodyLimit` of a route on its path (the POST, PUT,
/// PATCH or DELETE one) allows that length; otherwise it is answered `413`
/// unread.
final class MethodOverrideMiddleware implements Middleware {
  /// Reads `_method` from a `POST` form, as Laravel does for HTML forms.
  ///
  /// [keepRawBody] (set by `withUpstream`) keeps a form's bytes before they
  /// are parsed, so a request no route matches still reaches the upstream
  /// with its body: parsing a multipart body consumes the stream. Such a
  /// body is then buffered in memory in full (up to `HTTP_MAX_BODY`); an
  /// application that proxies large uploads sets
  /// `middleware.methodOverride = false` so they stream through unread.
  const MethodOverrideMiddleware({
    this.keepRawBody = false,
    this.router,
    this.defaultTimeout,
  });

  /// The methods a form may ask for.
  static const Set<String> allowed = {'PUT', 'PATCH', 'DELETE'};

  /// Whether a form's raw bytes are kept for `Request.bodyStream()`.
  final bool keepRawBody;

  /// The application's routes, resolved after boot. When supplied, a form
  /// is read only on a path with a PUT, PATCH or DELETE route.
  final Router Function()? router;

  /// The kernel's timeout for routes without their own.
  final Duration? Function()? defaultTimeout;

  @override
  Future<Response> handle(Request request, Next next) async {
    if (request.method == 'POST') {
      final (target, refusal) = await _target(request);
      if (refusal != null) {
        return refusal;
      }
      if (allowed.contains(target)) {
        request.overrideMethod(target!);
      }
    }
    return next(request);
  }

  /// The method [request] asks for, or the answer to give instead of
  /// reading its form.
  Future<(String?, Response?)> _target(Request request) async {
    final header = request.headers.first('x-http-method-override');
    if (header != null && header.isNotEmpty) {
      return (header.toUpperCase(), null);
    }
    final contentType = (request.headers.contentType ?? '').toLowerCase();
    final isForm =
        contentType.contains('application/x-www-form-urlencoded') ||
        contentType.contains('multipart/form-data');
    if (!isForm) {
      return (_queryTarget(request), null);
    }
    final routes = router?.call();
    Duration? timeout;
    var reachable = const <RouteEntry>[];
    if (routes != null) {
      final candidates = [
        for (final method in allowed)
          ?routes.lookup(method, request.path, host: request.host)?.value,
      ];
      if (candidates.isEmpty) {
        return (_queryTarget(request), null);
      }
      reachable = [
        ...candidates,
        ?routes.lookup('POST', request.path, host: request.host)?.value,
      ];
      timeout = _timeoutFor(reachable);
    }
    if (!bodyRefusalDeferred(request)) {
      return (await _formTarget(request, timeout), null);
    }
    // BodyLimitsMiddleware saw a declared length over its limit and left
    // the answer to the route's bodyLimit. The route is still unknown
    // here, so the form is read only when a route it can reach allows the
    // declared length, and under that limit for this read alone: the
    // kernel then decides by the route that matches.
    final widest = _widestBodyLimit(reachable);
    final declared = request.contentLength;
    if (widest == null || declared == null || declared > widest) {
      return (null, payloadTooLargeResponse());
    }
    final lowered = request.maxBodyBytes;
    request.maxBodyBytes = widest;
    try {
      return (await _formTarget(request, timeout), null);
    } finally {
      request.maxBodyBytes = lowered;
    }
  }

  Future<String?> _formTarget(Request request, Duration? timeout) async {
    final reading = _read(request);
    final body = timeout == null
        ? await reading
        : await reading.timeout(
            timeout,
            onTimeout: () {
              final error = ServiceUnavailableHttpException(
                'The request did not complete within ${timeout.inSeconds}s.',
              );
              request.abortBodyRead(error);
              throw error;
            },
          );
    final value = body is Map ? body['_method'] : null;
    return switch (value ?? request.queryInput['_method']) {
      final String method => method.toUpperCase(),
      _ => null,
    };
  }

  /// The largest `bodyLimit` among [routes]; `null` when none sets one.
  int? _widestBodyLimit(List<RouteEntry> routes) {
    int? widest;
    for (final route in routes) {
      final limit = route.bodyLimitBytes;
      if (limit != null && (widest == null || limit > widest)) {
        widest = limit;
      }
    }
    return widest;
  }

  String? _queryTarget(Request request) =>
      switch (request.queryInput['_method']) {
        final String method => method.toUpperCase(),
        _ => null,
      };

  /// Before routing, allow the longest timeout of every reachable route.
  /// An unlimited route keeps the read unlimited, too.
  Duration? _timeoutFor(List<RouteEntry> routes) {
    var longest = Duration.zero;
    for (final route in routes) {
      final timeout = route.timeoutDuration ?? defaultTimeout?.call();
      if (timeout == null) {
        return null;
      }
      if (timeout > longest) {
        longest = timeout;
      }
    }
    return longest;
  }

  Future<Object?> _read(Request request) async {
    if (keepRawBody) {
      // Cached first: body() and bodyStream() then read these bytes.
      await request.bytes();
    }
    return request.body();
  }
}
