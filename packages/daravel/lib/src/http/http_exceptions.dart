import '../foundation/exceptions.dart';

/// An exception that maps directly to an HTTP response (ADR-009).
class HttpException extends DaravelException {
  const HttpException(
    this.status,
    String message, {
    this.headers = const <String, String>{},
  }) : super(message);

  /// HTTP status code.
  final int status;

  /// Extra headers to send with the rendered response.
  final Map<String, String> headers;
}

final class BadRequestHttpException extends HttpException {
  const BadRequestHttpException([String message = 'Bad Request'])
    : super(400, message);
}

final class UnauthorizedHttpException extends HttpException {
  const UnauthorizedHttpException([String message = 'Unauthenticated.'])
    : super(401, message);
}

final class ForbiddenHttpException extends HttpException {
  const ForbiddenHttpException([
    String message = 'This action is unauthorized.',
  ]) : super(403, message);
}

final class NotFoundHttpException extends HttpException {
  const NotFoundHttpException([String message = 'Not Found'])
    : super(404, message);
}

final class MethodNotAllowedHttpException extends HttpException {
  MethodNotAllowedHttpException(this.allowedMethods, String message)
    : super(
        405,
        message,
        headers: <String, String>{'allow': allowedMethods.join(', ')},
      );

  /// Methods that are supported for the requested path.
  final List<String> allowedMethods;
}

final class ServiceUnavailableHttpException extends HttpException {
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
Never abort(
  int status, [
  String? message,
  Map<String, String> headers = const <String, String>{},
]) => throw HttpException(
  status,
  message ?? reasonPhrases[status] ?? 'HTTP $status',
  headers: headers,
);
