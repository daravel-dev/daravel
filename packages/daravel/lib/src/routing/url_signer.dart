import 'dart:convert';

import '../foundation/clock.dart';

import 'package:crypto/crypto.dart';

/// Signs and verifies URLs with HMAC-SHA256 (Laravel `URL::signedRoute`).
///
/// The signature covers the path and query string (not the scheme/host), so
/// links stay valid behind reverse proxies that rewrite the host; this is a
/// documented deviation from Laravel, which signs the absolute URL.
final class UrlSigner {
  UrlSigner(List<int> key) : _hmac = Hmac(sha256, key);

  /// Builds a signer from an `APP_KEY` value (`base64:...` or raw text).
  factory UrlSigner.fromAppKey(String appKey) {
    const prefix = 'base64:';
    final bytes = appKey.startsWith(prefix)
        ? base64.decode(appKey.substring(prefix.length))
        : utf8.encode(appKey);
    return UrlSigner(bytes);
  }

  static const String signatureParam = 'signature';
  static const String expiresParam = 'expires';

  final Hmac _hmac;

  /// Appends `expires` (optional) and `signature` to [pathAndQuery].
  String sign(String pathAndQuery, {DateTime? expires}) {
    var base = pathAndQuery;
    if (expires != null) {
      base = _append(
        base,
        expiresParam,
        '${expires.toUtc().millisecondsSinceEpoch ~/ 1000}',
      );
    }
    return _append(base, signatureParam, _signature(base));
  }

  /// Whether [uri] carries a valid, unexpired signature.
  bool verify(Uri uri, {DateTime? now}) {
    final signature = uri.queryParameters[signatureParam];
    if (signature == null || signature.isEmpty) {
      return false;
    }
    final expires = uri.queryParameters[expiresParam];
    if (expires != null) {
      final seconds = int.tryParse(expires);
      if (seconds == null) {
        return false;
      }
      final current =
          (now ?? Clock.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      if (current > seconds) {
        return false;
      }
    }
    final stripped = _stripSignature(uri);
    return _constantTimeEquals(_signature(stripped), signature);
  }

  String _signature(String data) => _hmac.convert(utf8.encode(data)).toString();

  static String _append(String base, String key, String value) {
    final separator = base.contains('?') ? '&' : '?';
    return '$base$separator${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}';
  }

  /// Rebuilds `path?query` from [uri] without the signature parameter,
  /// preserving the original parameter order.
  static String _stripSignature(Uri uri) {
    if (uri.query.isEmpty) {
      return uri.path;
    }
    final kept = uri.query
        .split('&')
        .where(
          (pair) => pair.isNotEmpty && !pair.startsWith('$signatureParam='),
        )
        .join('&');
    return kept.isEmpty ? uri.path : '${uri.path}?$kept';
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
