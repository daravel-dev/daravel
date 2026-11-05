import '../csp.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Conservative security headers for API responses (BLUEPRINT_V2 §9.2).
/// Headers already set by the handler are preserved.
final class SecurityHeadersMiddleware implements Middleware {
  /// Adds `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`
  /// and, over HTTPS, `Strict-Transport-Security`; with
  /// [contentSecurityPolicy], also `Content-Security-Policy` on HTML
  /// responses.
  const SecurityHeadersMiddleware({
    this.frameOptions = 'DENY',
    this.referrerPolicy = 'strict-origin-when-cross-origin',
    this.hstsMaxAge = const Duration(days: 365),
    this.noStoreWhenAuthenticated = true,
    this.contentSecurityPolicy,
  });

  /// `X-Frame-Options` applied to HTML responses.
  final String frameOptions;

  /// The `Referrer-Policy` value.
  final String referrerPolicy;

  /// `Strict-Transport-Security` max-age, sent only on HTTPS requests.
  final Duration hstsMaxAge;

  /// Adds `Cache-Control: no-store` when an `Authorization` header is present.
  final bool noStoreWhenAuthenticated;

  /// The `Content-Security-Policy` (or, with `Csp(reportOnly: true)`,
  /// `Content-Security-Policy-Report-Only`) of HTML responses; `null`, the
  /// default, sends none. A policy that lists `Csp.nonce` is sent with the
  /// request's [Request.cspNonce], so the inline scripts and styles of the
  /// page that carry it run. A handler that sets the header itself keeps
  /// its own.
  final Csp? contentSecurityPolicy;

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
      final csp = contentSecurityPolicy;
      if (csp != null) {
        setIfAbsent(
          csp.headerName,
          csp.render(nonce: csp.usesNonce ? request.cspNonce : null),
        );
      }
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
