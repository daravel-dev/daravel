import '../exception_handler.dart';
import '../http_exceptions.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Request body limits (BLUEPRINT_V2 §2.3). Defaults: 1 MiB for JSON and
/// form bodies, 50 MiB for multipart/other bodies, JSON nesting ≤ 64.
///
/// Limits are enforced lazily by [Request.bytes] / [Request.body], after a
/// cheap `content-length` pre-check, so a request that never reads its body
/// costs nothing. Routes may override the byte limit with
/// `RouteEntry.bodyLimit`.
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

  /// The deepest nesting a JSON body may have; deeper is refused with 400.
  /// Apart from it, a body nested `Request.jsonMaxDepth` (512) deep or
  /// deeper is read as no input, as Laravel reads it.
  final int jsonDepth;

  /// Byte limit that applies to [request] based on its content type.
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
    request.maxBodyBytes = limitFor(request);
    request.maxJsonDepth = jsonDepth;
    final declared = request.contentLength;
    if (declared != null && declared > request.maxBodyBytes!) {
      return Future<Response>.value(
        // Laravel's ValidatePostSize message; the limit is not disclosed.
        laravelErrorResponse(<String, Object?>{
          'message': const PayloadTooLargeHttpException().message,
        }, status: 413),
      );
    }
    return next(request);
  }
}
