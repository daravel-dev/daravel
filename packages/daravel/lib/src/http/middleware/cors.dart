import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// CORS configuration (`config/cors.php` parity).
final class CorsConfig {
  const CorsConfig({
    this.allowedOrigins = const <String>[],
    this.allowedMethods = const <String>['*'],
    this.allowedHeaders = const <String>['*'],
    this.exposedHeaders = const <String>[],
    this.maxAge = const Duration(hours: 1),
    this.supportsCredentials = false,
  });

  /// Exact origins, `*`, or wildcard patterns such as `https://*.example.com`.
  final List<String> allowedOrigins;
  final List<String> allowedMethods;
  final List<String> allowedHeaders;
  final List<String> exposedHeaders;
  final Duration maxAge;
  final bool supportsCredentials;
}

/// Cross-origin resource sharing. Secure by default: no origin is allowed
/// until configured, and `*` is never combined with credentials
/// (BLUEPRINT_V2 §9.2).
final class CorsMiddleware implements Middleware {
  CorsMiddleware([this.config = const CorsConfig()])
    : _patterns = config.allowedOrigins
          .where((origin) => origin != '*')
          .map(_toPattern)
          .toList(growable: false),
      _allowAny = config.allowedOrigins.contains('*') {
    if (_allowAny && config.supportsCredentials) {
      throw ArgumentError(
        'CORS: allowedOrigins "*" cannot be combined with supportsCredentials; '
        'list explicit origins instead.',
      );
    }
  }

  final CorsConfig config;
  final List<RegExp> _patterns;
  final bool _allowAny;

  static RegExp _toPattern(String origin) => RegExp(
    '^${RegExp.escape(origin).replaceAll(r'\*', '[^.]+')}\$',
    caseSensitive: false,
  );

  /// Whether [origin] is allowed by the configuration.
  bool allowsOrigin(String origin) =>
      _allowAny || _patterns.any((pattern) => pattern.hasMatch(origin));

  bool _isPreflight(Request request) =>
      request.method == 'OPTIONS' &&
      request.headers.has('access-control-request-method');

  @override
  Future<Response> handle(Request request, Next next) async {
    final origin = request.headers.first('origin');
    if (origin == null) {
      return next(request);
    }
    if (!allowsOrigin(origin)) {
      if (_isPreflight(request)) {
        return Response.noContent().withHeader('vary', 'Origin');
      }
      final response = await next(request);
      return response.withHeader('vary', 'Origin');
    }
    if (_isPreflight(request)) {
      return _decorate(
        Response.noContent(),
        origin,
        preflight: true,
        request: request,
      );
    }
    final response = await next(request);
    return _decorate(response, origin, preflight: false, request: request);
  }

  Response _decorate(
    Response response,
    String origin, {
    required bool preflight,
    required Request request,
  }) {
    final headers = <String, String>{
      'access-control-allow-origin': _allowAny && !config.supportsCredentials
          ? '*'
          : origin,
      'vary': 'Origin',
    };
    if (config.supportsCredentials) {
      headers['access-control-allow-credentials'] = 'true';
    }
    if (preflight) {
      headers['access-control-allow-methods'] =
          config.allowedMethods.contains('*')
          ? (request.headers.first('access-control-request-method') ??
                'GET, POST')
          : config.allowedMethods.join(', ');
      final requested = request.headers.first('access-control-request-headers');
      headers['access-control-allow-headers'] =
          config.allowedHeaders.contains('*')
          ? (requested ?? '*')
          : config.allowedHeaders.join(', ');
      headers['access-control-max-age'] = '${config.maxAge.inSeconds}';
    } else if (config.exposedHeaders.isNotEmpty) {
      headers['access-control-expose-headers'] = config.exposedHeaders.join(
        ', ',
      );
    }
    return response.withHeaders(headers);
  }
}
