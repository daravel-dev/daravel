import '../foundation/exceptions.dart';

/// An exception that maps directly to an HTTP response (ADR-009).
class HttpException extends DaravelException {
  /// An HTTP error with [statusCode] and a message; the exception handler
  /// turns it into the response.
  const HttpException(
    this.status,
    String message, {
    this.headers = const <String, String>{},
  }) : super(message);

  /// HTTP status code.
  final int status;

  /// Extra headers to send with the rendered response.
  final Map<String, String> headers;

  /// Whether the default renderer writes the body pretty-printed, as
  /// Laravel's `Handler::prepareJsonResponse` does for every HTTP error
  /// (`JSON_PRETTY_PRINT`). `AuthenticationException` overrides it: Laravel
  /// answers that one with a plain `response()->json`.
  bool get prettyJson => true;
}

/// A 400 Bad Request.
final class BadRequestHttpException extends HttpException {
  /// A 400 with [message].
  const BadRequestHttpException([String message = 'Bad Request'])
    : super(400, message);
}

/// A 401: the request is not authenticated.
final class UnauthorizedHttpException extends HttpException {
  /// A 401 with [message] (`Unauthenticated.`).
  const UnauthorizedHttpException([String message = 'Unauthenticated.'])
    : super(401, message);
}

/// A 403: the user may not do this.
final class ForbiddenHttpException extends HttpException {
  /// A 403 with a message (`This action is unauthorized.`).
  const ForbiddenHttpException([
    String message = 'This action is unauthorized.',
  ]) : super(403, message);
}

/// A 404 Not Found.
final class NotFoundHttpException extends HttpException {
  /// A 404 with [message].
  const NotFoundHttpException([String message = '']) : super(404, message);
}

/// A 405: the route exists, but not for this method.
final class MethodNotAllowedHttpException extends HttpException {
  /// A 405 listing the [allowedMethods] in its `Allow` header.
  MethodNotAllowedHttpException(this.allowedMethods, String message)
    : super(
        405,
        message,
        headers: <String, String>{'allow': allowedMethods.join(', ')},
      );

  /// Methods that are supported for the requested path.
  final List<String> allowedMethods;
}

/// A 413: the body is larger than allowed.
final class PayloadTooLargeHttpException extends HttpException {
  /// A 413 with a message.
  const PayloadTooLargeHttpException([
    String message = 'The POST data is too large.',
  ]) : super(413, message);
}

/// A 503: the application cannot serve the request now.
final class ServiceUnavailableHttpException extends HttpException {
  /// A 503 with a message.
  const ServiceUnavailableHttpException([
    String message = 'Service Unavailable',
  ]) : super(503, message);
}

/// Standard reason phrases used when aborting without a custom message.
const Map<int, String> reasonPhrases = <int, String>{
  400: 'Bad Request',
  401: 'Unauthorized',
  402: 'Payment Required',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  406: 'Not Acceptable',
  408: 'Request Timeout',
  409: 'Conflict',
  410: 'Gone',
  413: 'Payload Too Large',
  415: 'Unsupported Media Type',
  419: 'Page Expired',
  422: 'Unprocessable Content',
  429: 'Too Many Requests',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
  504: 'Gateway Timeout',
};

/// Throws an [HttpException] with [status] (Laravel's `abort()` helper).
///
/// Like Laravel, the JSON message is empty unless [message] is given.
Never abort(
  int status, [
  String? message,
  Map<String, String> headers = const <String, String>{},
]) => throw HttpException(status, message ?? '', headers: headers);

/// Aborts with [status] when [condition] is true (`abort_if()`).
void abortIf(
  bool condition,
  int status, [
  String? message,
  Map<String, String> headers = const <String, String>{},
]) {
  if (condition) {
    abort(status, message, headers);
  }
}

/// Aborts with [status] unless [condition] is true (`abort_unless()`).
void abortUnless(
  bool condition,
  int status, [
  String? message,
  Map<String, String> headers = const <String, String>{},
]) {
  if (!condition) {
    abort(status, message, headers);
  }
}
