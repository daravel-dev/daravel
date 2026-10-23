import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Conservative security headers for API responses (BLUEPRINT_V2 §9.2).
/// Headers already set by the handler are preserved.
final class SecurityHeadersMiddleware implements Middleware {
  const SecurityHeadersMiddleware({
    this.frameOptions = 'DENY',
    this.referrerPolicy = 'strict-origin-when-cross-origin',
    this.hstsMaxAge = const Duration(days: 365),
    this.noStoreWhenAuthenticated = true,
  });

  /// `X-Frame-Options` applied to HTML responses.
  final String frameOptions;
  final String referrerPolicy;

  /// `Strict-Transport-Security` max-age, sent only on HTTPS requests.
  final Duration hstsMaxAge;

  /// Adds `Cache-Control: no-store` when an `Authorization` header is present.
  final bool noStoreWhenAuthenticated;

  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    final headers = <String, String>{};
    void setIfAbsent(String name, String value) {
      if (!response.headers.has(name)) {
        headers[name] = value;
      }
    }

    setIfAbsent('x-content-type-options', 'nosniff');
    setIfAbsent('referrer-policy', referrerPolicy);
    final contentType = (response.headers.contentType ?? '').toLowerCase();
    if (contentType.contains('text/html')) {
      setIfAbsent('x-frame-options', frameOptions);
    }
    if (request.isSecure) {
      setIfAbsent(
        'strict-transport-security',
        'max-age=${hstsMaxAge.inSeconds}; includeSubDomains',
      );
    }
    if (noStoreWhenAuthenticated && request.headers.has('authorization')) {
      setIfAbsent('cache-control', 'no-store');
    }
    return headers.isEmpty ? response : response.withHeaders(headers);
  }
}
