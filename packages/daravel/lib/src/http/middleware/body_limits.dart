import '../../foundation/env.dart';
import '../body_limit_refusal.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// The request body limits Daravel applies by default, in one place: the
/// engine gives every JSON and form body [json] and [form] (since 1.28.0,
/// as `BodyLimitsMiddleware` already did), and [BodyLimitsMiddleware]
/// starts from all four. The middleware's limits replace the engine's JSON
/// and form limits but never exceed `HTTP_MAX_BODY`; a route's `bodyLimit`
/// replaces them all and may be larger.
abstract final class BodyLimits {
  /// The largest JSON body, in bytes: 1 MiB.
  static const int json = 1 << 20;

  /// The largest `application/x-www-form-urlencoded` body, in bytes: 1 MiB.
  static const int form = 1 << 20;

  /// The largest body of any other type, in bytes: 50 MiB, as
  /// [Request.defaultMaxBodyBytes] (`HTTP_MAX_BODY`).
  static const int other = Request.defaultMaxBodyBytes;

  /// The deepest JSON nesting [BodyLimitsMiddleware] accepts (a `400`
  /// beyond it).
  static const int jsonDepth = 64;

  /// Whether [contentType] (lowercase) is a JSON body: `application/json`
  /// and the `+json` types.
  static bool isJson(String contentType) => contentType.contains('json');

  /// Whether [contentType] (lowercase) is a form body.
  static bool isForm(String contentType) =>
      contentType.contains('application/x-www-form-urlencoded');

  /// The engine's JSON limit from `HTTP_MAX_JSON_BODY` (bytes): unset means
  /// [json], `0` no limit of its own (only `HTTP_MAX_BODY` applies, as
  /// before 1.28.0); a negative value is an error at boot.
  static int? jsonFromEnv(Env env) => _fromEnv(env, 'HTTP_MAX_JSON_BODY', json);

  /// The engine's form limit from `HTTP_MAX_FORM_BODY`, as [jsonFromEnv].
  static int? formFromEnv(Env env) => _fromEnv(env, 'HTTP_MAX_FORM_BODY', form);

  static int? _fromEnv(Env env, String name, int fallback) {
    final value = env.integer(name, fallback);
    if (value < 0) {
      throw ArgumentError.value(
        value,
        name,
        'must be a positive number of bytes, or 0 for no limit of its own',
      );
    }
    return value == 0 ? null : value;
  }

  /// The limit of [request]'s body type among [json] and [form] (the
  /// engine's, or a middleware's), `null` for any other type.
  static int? forType(Request request, {int? json, int? form}) {
    final contentType = (request.headers.contentType ?? '').toLowerCase();
    if (isJson(contentType)) {
      return json;
    }
    if (isForm(contentType)) {
      return form;
    }
    return null;
  }
}

/// Request body limits (BLUEPRINT_V2 §2.3). Defaults: 1 MiB for JSON and
/// form bodies, 50 MiB for multipart/other bodies, JSON nesting ≤ 64
/// ([BodyLimits]).
///
/// Without this middleware the engine still limits JSON and form bodies to
/// `HTTP_MAX_JSON_BODY` and `HTTP_MAX_FORM_BODY` (1 MiB by default). With
/// it, its limits replace those two, also when they are larger, but never
/// exceed the limit the request arrived with (`ServeOptions.maxBodyBytes`,
/// `HTTP_MAX_BODY`): the smaller of the two applies, so a limit here above
/// `HTTP_MAX_BODY` has no effect. A route that needs more sets
/// `RouteEntry.bodyLimit`, which replaces them all and may be larger than
/// `HTTP_MAX_BODY`.
///
/// Limits are enforced lazily by [Request.bytes] / [Request.body], after a
/// cheap `content-length` pre-check, so a request that never reads its body
/// costs nothing. As global middleware it runs before the route is known:
/// a declared `content-length` over the limit is then refused by the kernel
/// once the route is looked up (`413`, before the route middleware and the
/// handler, and instead of a `404` or `405`), unless the route's
/// `bodyLimit` allows it. On a route or a route group it answers the `413`
/// itself.
final class BodyLimitsMiddleware implements Middleware {
  /// Limits by body type; the defaults are 1 MiB for JSON and forms.
  const BodyLimitsMiddleware({
    this.json = BodyLimits.json,
    this.form = BodyLimits.form,
    this.other = BodyLimits.other,
    this.jsonDepth = BodyLimits.jsonDepth,
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

  /// The byte limit of the route of [request] (`RouteEntry.bodyLimit`) when
  /// it has one, otherwise the limit of its content type. [handle] lowers
  /// the latter to the limit the request arrived with (`HTTP_MAX_BODY`).
  int limitFor(Request request) =>
      request.route?.bodyLimitBytes ??
      BodyLimits.forType(request, json: json, form: form) ??
      other;

  @override
  Future<Response> handle(Request request, Next next) {
    final route = request.route;
    var limit = limitFor(request);
    if (route?.bodyLimitBytes == null) {
      // Never above what the request arrived with (HTTP_MAX_BODY); the
      // engine's JSON and form limits, applied since, are replaced.
      final ceiling = arrivedBodyLimit(request);
      if (ceiling != null && ceiling < limit) {
        limit = ceiling;
      }
    }
    request.maxBodyBytes = limit;
    request.maxJsonDepth = jsonDepth;
    final declared = request.contentLength;
    // Declared over the limit, or already read over it (on a route group,
    // after something read the body before routing; chunked, it declares
    // nothing).
    if ((declared != null && declared > limit) ||
        request.bodyBytesRead > limit) {
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
