import 'dart:io' show HttpDate;

import '../foundation/clock.dart';
import '../foundation/php.dart';
import 'headers.dart';

/// Parses the `Cookie` request headers into name/value pairs, the way PHP
/// fills `$_COOKIE`: values are URL-decoded (`+` is a space) and the first
/// occurrence of a name wins.
Map<String, String> parseRequestCookies(Headers headers) {
  final cookies = <String, String>{};
  for (final line in headers.all('cookie')) {
    for (final part in line.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final name = part.substring(0, separator).trim();
      if (name.isEmpty || cookies.containsKey(name)) {
        continue;
      }
      cookies[name] = _decode(part.substring(separator + 1).trim());
    }
  }
  return cookies;
}

String _decode(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } on ArgumentError {
    return value;
  } on FormatException {
    return value;
  }
}

/// A `Set-Cookie` header value in the format Laravel sends (Symfony's
/// `Cookie::__toString`): the value is `rawurlencode`d, attributes are
/// lower case, and a lifetime adds both `expires` and `Max-Age`.
///
/// [maxAge] `null` makes a session cookie. [sameSite] is `lax`, `strict`,
/// `none` or `null` (no attribute).
String formatSetCookie(
  String name,
  String value, {
  Duration? maxAge,
  String path = '/',
  String? domain,
  bool secure = false,
  bool httpOnly = true,
  String? sameSite = 'lax',
}) {
  _checkName(name);
  final buffer = StringBuffer('$name=');
  if (value.isEmpty) {
    // Symfony writes an emptied cookie as a deletion.
    final past = Clock.now().toUtc().subtract(
      const Duration(seconds: 31536001),
    );
    buffer.write('deleted; expires=${HttpDate.format(past)}; Max-Age=0');
  } else {
    buffer.write(phpRawUrlEncode(value));
    if (maxAge != null) {
      final seconds = maxAge.inSeconds < 0 ? 0 : maxAge.inSeconds;
      final expires = Clock.now().toUtc().add(Duration(seconds: seconds));
      buffer.write('; expires=${HttpDate.format(expires)}; Max-Age=$seconds');
    }
  }
  buffer.write('; path=$path');
  if (domain != null && domain.isNotEmpty) {
    buffer.write('; domain=$domain');
  }
  if (secure) {
    buffer.write('; secure');
  }
  if (httpOnly) {
    buffer.write('; httponly');
  }
  if (sameSite != null) {
    final lower = sameSite.toLowerCase();
    if (lower != 'lax' && lower != 'strict' && lower != 'none') {
      throw ArgumentError.value(sameSite, 'sameSite', 'lax, strict or none');
    }
    buffer.write('; samesite=$lower');
  }
  return buffer.toString();
}

void _checkName(String name) {
  if (name.isEmpty || RegExp(r'[=,; \t\r\n\x0b\x0c]').hasMatch(name)) {
    throw ArgumentError.value(name, 'name', 'not a valid cookie name');
  }
}
