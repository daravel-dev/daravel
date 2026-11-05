import 'dart:io' show HttpDate;

import 'package:daravel/daravel.dart';

/// One `Set-Cookie` header of a response.
final class ResponseCookie {
  /// A cookie [name] with its [rawValue] as sent.
  const ResponseCookie({
    required this.name,
    required this.rawValue,
    this.path,
    this.maxAge,
    this.expires,
  });

  /// Parses a `Set-Cookie` header value (`name=value; path=/; Max-Age=0`);
  /// `null` when it has no name.
  static ResponseCookie? parse(String line) {
    final parts = line.split(';');
    final pair = parts.first;
    final separator = pair.indexOf('=');
    if (separator <= 0) {
      return null;
    }
    String? path;
    int? maxAge;
    DateTime? expires;
    for (final attribute in parts.skip(1)) {
      final equals = attribute.indexOf('=');
      final key = (equals == -1 ? attribute : attribute.substring(0, equals))
          .trim()
          .toLowerCase();
      final value = equals == -1 ? '' : attribute.substring(equals + 1).trim();
      switch (key) {
        case 'path':
          path = value.isEmpty ? null : value;
        case 'max-age':
          maxAge = int.tryParse(value);
        case 'expires':
          try {
            expires = HttpDate.parse(value);
          } on Object {
            expires = null;
          }
      }
    }
    return ResponseCookie(
      name: pair.substring(0, separator).trim(),
      rawValue: pair.substring(separator + 1).trim(),
      path: path,
      maxAge: maxAge,
      expires: expires,
    );
  }

  /// The name.
  final String name;

  /// The value as sent (`rawurlencode`d by Daravel and Laravel).
  final String rawValue;

  /// The `path` attribute, when there is one.
  final String? path;

  /// The `Max-Age` attribute in seconds, when there is one.
  final int? maxAge;

  /// The `expires` attribute, when there is one.
  final DateTime? expires;

  /// The value, URL-decoded.
  String get value {
    try {
      return Uri.decodeComponent(rawValue);
    } on ArgumentError {
      return rawValue;
    }
  }

  /// When the cookie stops being sent: `Max-Age` wins over `expires`, as
  /// in browsers; `null` for a session cookie. Measured with `Clock.now()`,
  /// so `travel()` expires cookies.
  DateTime? expiresAt(DateTime now) =>
      maxAge != null ? now.add(Duration(seconds: maxAge!)) : expires;

  /// Whether the cookie is already expired, which deletes it (Laravel's
  /// `Cookie::forget` sends `Max-Age=0`).
  bool get expired {
    final now = Clock.now();
    if (maxAge != null) {
      return maxAge! <= 0;
    }
    return expires != null && !expires!.isAfter(now);
  }
}

final class _StoredCookie {
  _StoredCookie(this.name, this.rawValue, this.path, this.expiresAt);

  final String name;
  final String rawValue;
  final String path;
  final DateTime? expiresAt;

  bool get alive => expiresAt == null || expiresAt!.isAfter(Clock.now());
}

/// What a browser keeps between requests for `TestClient.browser()`: the
/// cookies of every `Set-Cookie` header, sent back on the requests whose
/// path they match. A cookie with `Max-Age=0` or an `expires` in the past
/// is deleted, and expiry is measured with `Clock.now()`, so `travel()`
/// lets a cookie run out.
final class CookieJar {
  final Map<(String, String), _StoredCookie> _cookies = {};

  /// Stores the `Set-Cookie` [lines] of a response to a request for [uri].
  void receive(Iterable<String> lines, Uri uri) {
    for (final line in lines) {
      final cookie = ResponseCookie.parse(line);
      if (cookie == null) {
        continue;
      }
      final path = cookie.path ?? _defaultPath(uri.path);
      final key = (cookie.name, path);
      if (cookie.expired) {
        _cookies.remove(key);
        continue;
      }
      _cookies[key] = _StoredCookie(
        cookie.name,
        cookie.rawValue,
        path,
        cookie.expiresAt(Clock.now()),
      );
    }
  }

  /// Sets cookie [name] to [value] (sent as given, URL-encoded), as a
  /// browser that already holds it.
  void put(String name, String value, {String path = '/'}) =>
      _cookies[(name, path)] = _StoredCookie(
        name,
        phpRawUrlEncode(value),
        path,
        null,
      );

  /// Deletes cookie [name] on every path.
  void forget(String name) => _cookies.removeWhere((key, _) => key.$1 == name);

  /// Deletes every cookie.
  void clear() => _cookies.clear();

  /// The live cookies, URL-decoded, by name.
  Map<String, String> get all => {
    for (final cookie in _live())
      cookie.name: ResponseCookie(
        name: cookie.name,
        rawValue: cookie.rawValue,
      ).value,
  };

  /// The value of cookie [name], URL-decoded, or `null`.
  String? operator [](String name) => all[name];

  /// The cookies a browser sends to [uri], as `name=value` pairs with the
  /// longest path first.
  List<String> pairsFor(Uri uri) {
    final matching = [
      for (final cookie in _live())
        if (_pathMatches(uri.path.isEmpty ? '/' : uri.path, cookie.path))
          cookie,
    ]..sort((a, b) => b.path.length.compareTo(a.path.length));
    return [for (final cookie in matching) '${cookie.name}=${cookie.rawValue}'];
  }

  Iterable<_StoredCookie> _live() {
    _cookies.removeWhere((_, cookie) => !cookie.alive);
    return _cookies.values;
  }

  /// RFC 6265 §5.1.4.
  static bool _pathMatches(String requestPath, String cookiePath) {
    if (requestPath == cookiePath) {
      return true;
    }
    if (!requestPath.startsWith(cookiePath)) {
      return false;
    }
    return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
  }

  /// RFC 6265 §5.1.4 default-path.
  static String _defaultPath(String path) {
    if (path.isEmpty || !path.startsWith('/')) {
      return '/';
    }
    final last = path.lastIndexOf('/');
    return last == 0 ? '/' : path.substring(0, last);
  }
}
