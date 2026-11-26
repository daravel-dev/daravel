import '../body_limit_refusal.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Request body limits (BLUEPRINT_V2 §2.3). Defaults: 1 MiB for JSON and
/// form bodies, 50 MiB for multipart/other bodies, JSON nesting ≤ 64.
///
/// The middleware only lowers the limit a request arrived with
/// (`ServeOptions.maxBodyBytes`, `HTTP_MAX_BODY`): the smaller of the two
/// applies, so a limit here above `HTTP_MAX_BODY` has no effect. A route
/// that needs more sets `RouteEntry.bodyLimit`, which replaces both and
/// may be larger than `HTTP_MAX_BODY`.
///
/// Limits are enforced lazily by [Request.bytes] / [Request.body], after a
/// cheap `content-length` pre-check, so a request that never reads its body
/// costs nothing. As global middleware it runs before the route is known:
/// a declared `content-length` over the limit is then refused by the kernel
/// once the route is looked up (`413`, before the route middleware and the
/// handler), unless the route's `bodyLimit` allows it.
final class BodyLimitsMiddleware implements Middleware {
  /// Limits by body type; the defaults are 1 MiB for JSON and forms.
  const BodyLimitsMiddleware({
    this.json = 1 << 20,
    this.form = 1 << 20,
    this.other = 50 << 20,
    this.jsonDepth = 64,
  });

  /// The largest JSON body, in bytes.
  final int json;

  /// The largest form body, in bytes.
  final int form;

  /// The largest body of any other type, in bytes.
  final int other;

  /// The deepest nesting a JSON body may have.
  final int jsonDepth;

  /// The byte limit of the route of [request] (`RouteEntry.bodyLimit`) when
  /// it has one, otherwise the limit of its content type. [handle] never
  /// raises the limit the request arrived with to the latter.
  int limitFor(Request request) {
    final routeLimit = request.route?.bodyLimitBytes;
    if (routeLimit != null) {
      return routeLimit;
    }
    final contentType = (request.headers.contentType ?? '').toLowerCase();
    if (contentType.contains('json')) {
      return json;
    }
    if (contentType.contains('application/x-www-form-urlencoded')) {
      return form;
    }
    return other;
  }

  @override
  Future<Response> handle(Request request, Next next) {
    final route = request.route;
    var limit = limitFor(request);
    if (route?.bodyLimitBytes == null) {
      // Only ever lower what the request arrived with (HTTP_MAX_BODY).
      final arrived = request.maxBodyBytes;
      if (arrived != null && arrived < limit) {
        limit = arrived;
      }
    }
    request.maxBodyBytes = limit;
    request.maxJsonDepth = jsonDepth;
    final declared = request.contentLength;
    if (declared != null && declared > limit) {
      if (route != null) {
        return Future<Response>.value(payloadTooLargeResponse());
      }
      // Global middleware: the route is not known yet and its bodyLimit may
      // allow this body. The kernel refuses once it has looked the route up.
      deferBodyRefusal(request);
    }
    return next(request);
  }
}
