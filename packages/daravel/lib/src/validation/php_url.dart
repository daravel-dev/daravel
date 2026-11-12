/// PHP's `parse_url`, as far as Laravel's rules read it.
library;

/// The host PHP's `parse_url($url, PHP_URL_HOST)` returns (8.x
/// `php_url_parse_ex2`), or null when it returns none or fails:
/// - a scheme is letters, digits, `+`, `-` or `.` (`1http://x` has one);
///   without `//` after it there is no host, except where digits follow
///   the colon, read as a port (`example.com:80` is host and port);
/// - the host runs to the first `/`, `?` or `#`, after the last `@`;
/// - after the last `:` (none inside `[...]`) is a port: at most five
///   characters, `strtol` from 0 to 65535 (`+80` and `80x` are 80), or
///   the whole URL fails;
/// - control characters become `_`.
String? phpUrlHost(String url) {
  bool hasAt(int i, String c) => i < url.length && url[i] == c;
  int digitsFrom(int i, int max) {
    var j = i;
    while (j < url.length && j - i < max && _isDigit(url.codeUnitAt(j))) {
      j++;
    }
    return j;
  }

  final colon = url.indexOf(':');
  var start = 0;
  var portKnown = false;
  // parse_port, for a colon that may start a port: true to go on to the
  // host, false when there is none, null when parse_url fails.
  bool? port() {
    final from = colon + 1;
    final to = digitsFrom(from, 6);
    final count = to - from;
    if (count > 0 && count < 6 && (to == url.length || url[to] == '/')) {
      if (int.parse(url.substring(from, to)) > 65535) {
        return null;
      }
      portKnown = true;
      start = url.startsWith('//') ? 2 : 0;
      return true;
    }
    if (count == 0 && to == url.length) {
      return null;
    }
    if (url.startsWith('//')) {
      start = 2;
      return true;
    }
    return false;
  }

  if (colon > 0) {
    final scheme = url.substring(0, colon);
    if (!_scheme.hasMatch(scheme)) {
      final query = url.indexOf(RegExp('[?#]'));
      if (colon + 1 < url.length && (query < 0 || colon < query)) {
        if (port() != true) {
          return null;
        }
      } else if (url.startsWith('//')) {
        start = 2;
      } else {
        return null;
      }
    } else if (colon + 1 == url.length) {
      return null;
    } else if (!hasAt(colon + 1, '/')) {
      final to = digitsFrom(colon + 1, url.length);
      if ((to == url.length || url[to] == '/') && to - colon < 7) {
        if (port() != true) {
          return null;
        }
      } else {
        return null;
      }
    } else if (hasAt(colon + 2, '/')) {
      start = colon + 3;
      // file:/// is a path.
      if (scheme.toLowerCase() == 'file' && hasAt(colon + 3, '/')) {
        return null;
      }
    } else {
      return null;
    }
  } else if (colon == 0) {
    if (port() != true) {
      return null;
    }
  } else if (url.startsWith('//')) {
    start = 2;
  } else {
    return null;
  }

  var end = url.indexOf(RegExp('[/?#]'), start);
  if (end < 0) {
    end = url.length;
  }
  var authority = url.substring(start, end);
  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    authority = authority.substring(at + 1);
  }
  var host = authority;
  final bracketed = authority.startsWith('[') && authority.endsWith(']');
  final portColon = bracketed ? -1 : authority.lastIndexOf(':');
  if (portColon >= 0) {
    host = authority.substring(0, portColon);
    final text = authority.substring(portColon + 1);
    if (!portKnown && text.isNotEmpty) {
      if (text.length > 5) {
        return null;
      }
      final number = _strtol.firstMatch(text);
      if (number == null) {
        return null;
      }
      final value = int.parse(number[2]!);
      if ((number[1] == '-' && value != 0) || value > 65535) {
        return null;
      }
    }
  }
  if (host.isEmpty) {
    return null;
  }
  return host.replaceAll(_control, '_');
}

final RegExp _scheme = RegExp(r'^[A-Za-z0-9+.-]+$');

// strtol: leading white space, a sign, then digits.
final RegExp _strtol = RegExp(r'^[ \t\n\v\f\r]*([+-]?)(\d+)');

final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
