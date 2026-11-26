import 'exception_handler.dart';
import 'http_exceptions.dart';
import 'request.dart';
import 'response.dart';

/// Requests whose declared `Content-Length` is over the limit of
/// `BodyLimitsMiddleware` while their route is not known yet.
final Expando<bool> _awaitingRoute = Expando<bool>('bodyLimitAwaitingRoute');

/// Leaves the refusal of [request] to the kernel: `BodyLimitsMiddleware` ran
/// as global middleware, the declared `Content-Length` is over the limit,
/// and only the route can tell whether its `bodyLimit` allows the body.
void deferBodyRefusal(Request request) => _awaitingRoute[request] = true;

/// Whether `BodyLimitsMiddleware` left the refusal of [request] to the
/// kernel ([deferBodyRefusal]).
bool bodyRefusalDeferred(Request request) => _awaitingRoute[request] ?? false;

/// The `413` of a body over the limit: Laravel's `ValidatePostSize`
/// message; the limit is not disclosed.
Response payloadTooLargeResponse() => laravelErrorResponse(<String, Object?>{
  'message': const PayloadTooLargeHttpException().message,
}, status: 413);
