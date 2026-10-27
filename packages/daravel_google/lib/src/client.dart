import 'dart:convert';

import 'package:daravel/daravel.dart';

/// Google refused a call. [reason] is Google's: an API error's
/// `errors[0].reason` or `status` (`notFound`, `insufficientPermissions`,
/// `PERMISSION_DENIED`, ...), or an OAuth error code (`invalid_grant` when a
/// refresh token was revoked, `invalid_client`, ...).
final class GoogleException extends DaravelException {
  const GoogleException(super.message, {required this.status, this.reason});

  /// [response]'s error, in either of Google's shapes.
  factory GoogleException.from(String action, ClientResponse response) {
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    String? reason;
    String? message;
    if (body case {'error': final Map<String, Object?> error}) {
      // APIs: {"error": {"code", "message", "status", "errors": [{reason}]}}
      final errors = error['errors'];
      if (errors case [final Map<String, Object?> first, ...]) {
        reason = first['reason'] as String?;
      }
      reason ??= error['status'] as String?;
      message = error['message'] as String?;
    } else if (body case {'error': final String code}) {
      // OAuth: {"error": "invalid_grant", "error_description": "..."}
      reason = code;
      message = (body as Map<String, Object?>)['error_description'] as String?;
    }
    return GoogleException(
      '$action: ${message ?? reason ?? 'HTTP ${response.status}'}',
      status: response.status,
      reason: reason,
    );
  }

  final int status;
  final String? reason;
}

/// The HTTP client a Google client sends through: [own] when given, else
/// the application's (so `Http.fake()` stubs it), else a new one.
final class GoogleHttp {
  GoogleHttp(this._own);

  final HttpClientFactory? _own;
  HttpClientFactory? _fallback;

  HttpClientFactory get factory {
    if (_own case final HttpClientFactory http) {
      return http;
    }
    try {
      return Container.current.make<HttpClientFactory>();
    } on Object {
      return _fallback ??= HttpClientFactory();
    }
  }
}
