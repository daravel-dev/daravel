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
  const BodyLimitsMiddleware({
    this.json = 1 << 20,
    this.form = 1 << 20,
    this.other = 50 << 20,
    this.jsonDepth = 64,
  });

  final int json;
  final int form;
  final int other;
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
