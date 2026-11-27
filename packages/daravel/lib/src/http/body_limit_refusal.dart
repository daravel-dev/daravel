import 'exception_handler.dart';
import 'http_exceptions.dart';
import 'request.dart';
import 'response.dart';

/// Requests whose declared `Content-Length` is over the limit of
/// `BodyLimitsMiddleware` while their route is not known yet.
final Expando<bool> _awaitingRoute = Expando<bool>('bodyLimitAwaitingRoute');

/// The body limit each request arrived with, kept apart from "never
/// recorded": the limit itself may be `null` (no limit).
final Expando<_Arrived> _arrived = Expando<_Arrived>('bodyLimitArrived');

final class _Arrived {
  const _Arrived(this.bytes);

  final int? bytes;
}

/// Keeps the body limit [request] has now as the one it arrived with: what
/// the engine set from `HTTP_MAX_BODY`, or what a synthetic request
/// carries. The kernel calls it before it gives JSON and form bodies their
/// own limit. Only the first call for a request counts.
void recordArrivedBodyLimit(Request request) =>
    _arrived[request] ??= _Arrived(request.maxBodyBytes);

/// The body limit [request] arrived with ([recordArrivedBodyLimit]), the
/// ceiling of `BodyLimitsMiddleware`; `null` means no limit. For a request
/// the kernel never saw it is the limit the request has now.
int? arrivedBodyLimit(Request request) {
  final arrived = _arrived[request];
  return arrived == null ? request.maxBodyBytes : arrived.bytes;
}

/// Leaves the refusal of [request] to the kernel: `BodyLimitsMiddleware` ran
/// as global middleware, the body is over the limit (as declared, or as
/// already read), and only the route can tell whether its `bodyLimit`
/// allows the body.
void deferBodyRefusal(Request request) => _awaitingRoute[request] = true;

/// Whether `BodyLimitsMiddleware` left the refusal of [request] to the
/// kernel ([deferBodyRefusal]).
bool bodyRefusalDeferred(Request request) => _awaitingRoute[request] ?? false;

/// The `413` of a body over the limit: Laravel's `ValidatePostSize`
/// message; the limit is not disclosed.
Response payloadTooLargeResponse() => laravelErrorResponse(<String, Object?>{
  'message': const PayloadTooLargeHttpException().message,
}, status: 413);
