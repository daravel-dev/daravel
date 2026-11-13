/// The authority a `Host` header (RFC 9110 §7.2: `uri-host [ ":" port ]`),
/// the target of an absolute-form request line, or a trusted proxy's
/// `X-Forwarded-Host` names.
final class HostAuthority {
  /// [host] (an IPv6 address without its brackets) and [port], or none.
  const HostAuthority(this.host, this.port);

  /// The host, as sent.
  final String host;

  /// The port, or null for none.
  final int? port;
}

/// Reads [value] as `uri-host [ ":" port ]`, or returns null when it is not
/// one: what a client sends there must not change the path, query or host
/// the application sees (`/`, `?`, `#`, `@`, `\`, spaces and controls make
/// it null). The host is accepted as Symfony's `Request::getHost()` accepts
/// it (`isHostValid`): dot-separated labels of `[-a-zA-Z0-9_]` with an
/// optional final dot, a valid IPv4 address when the last label is
/// numeric, or a valid IPv6 address in brackets. A raw IDN is refused, as
/// there. A host longer than 253 characters, which no DNS name is (RFC 1035
/// §2.3.4), is refused too, though Symfony has no such limit: the host is
/// matched against domain routes. The port is digits up to 65535. An empty
/// value is an empty host.
///
/// One pass over [value], no regular expression: a `Host` line may be as
/// long as the header limit allows.
HostAuthority? parseHostAuthority(String value) {
  if (value.isEmpty) {
    return const HostAuthority('', null);
  }
  final String host;
  final String rest;
  if (value.codeUnitAt(0) == 0x5B) {
    // [IPv6]
    final close = value.indexOf(']');
    if (close < 0) {
      return null;
    }
    host = value.substring(1, close);
    if (!_isIpv6(host)) {
      return null;
    }
    rest = value.substring(close + 1);
  } else {
    final colon = value.indexOf(':');
    host = colon < 0 ? value : value.substring(0, colon);
    rest = colon < 0 ? '' : value.substring(colon);
    if (host.length > 253 || !_isNameOrIpv4(host)) {
      return null;
    }
  }
  if (rest.isEmpty) {
    return HostAuthority(host, null);
  }
  if (rest.codeUnitAt(0) != 0x3A) {
    return null;
  }
  final digits = rest.substring(1);
  if (digits.isEmpty) {
    return HostAuthority(host, null);
  }
  if (digits.length > 5) {
    return null;
  }
  var port = 0;
  for (var i = 0; i < digits.length; i++) {
    final c = digits.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) {
      return null;
    }
    port = port * 10 + (c - 0x30);
  }
  return port > 65535 ? null : HostAuthority(host, port);
}

bool _isIpv6(String address) {
  // Only hex digits, colons and the dots of an embedded IPv4 address: no
  // zone (`%`), which Uri.parseIPv6Address would not refuse on its own.
  for (var i = 0; i < address.length; i++) {
    final c = address.codeUnitAt(i);
    final ok =
        c == 0x3A ||
        c == 0x2E ||
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x46) ||
        (c >= 0x61 && c <= 0x66);
    if (!ok) {
      return false;
    }
  }
  try {
    Uri.parseIPv6Address(address);
    return true;
  } on FormatException {
    return false;
  }
}

bool _isNameOrIpv4(String host) {
  if (host.isEmpty) {
    return false;
  }
  var labelStart = 0;
  var labels = 0;
  var lastAllDigits = false;
  var allDigits = true;
  for (var i = 0; i <= host.length; i++) {
    if (i == host.length || host.codeUnitAt(i) == 0x2E) {
      final length = i - labelStart;
      if (length == 0) {
        // An empty label: only a final dot may end the name.
        if (i == host.length && i > 0 && labels > 0) {
          break;
        }
        return false;
      }
      labels++;
      lastAllDigits = allDigits;
      allDigits = true;
      labelStart = i + 1;
      continue;
    }
    final c = host.codeUnitAt(i);
    final digit = c >= 0x30 && c <= 0x39;
    final ok =
        digit ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x2D ||
        c == 0x5F;
    if (!ok) {
      return false;
    }
    if (!digit) {
      allDigits = false;
    }
  }
  // A numeric last label after a dot: then the whole host must be IPv4.
  if (labels > 1 && lastAllDigits) {
    return _isIpv4(host);
  }
  return true;
}

bool _isIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) {
    return false;
  }
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) {
      return false;
    }
    final value = int.tryParse(part);
    if (value == null || value > 255 || (part.length > 1 && part[0] == '0')) {
      return false;
    }
  }
  return true;
}
