import 'dart:math' as math;

/// [url] with the password in its user info masked as `***`, for error
/// messages and logs: `pgsql://app:***@db/shop`.
///
/// It does not need a valid URL, so it also works on the URL a parser has
/// just rejected. The authority starts after `scheme://` (a letter, then
/// letters, digits, `+`, `-`, `.`), after a leading `//`, or else at the
/// start of the text, and runs to the first `/`, `?` or `#`. Then:
///
/// | The authority | What is masked | Example |
/// | --- | --- | --- |
/// | holds an `@` | from its first `:` to its last `@` | `pgsql://u:p@ss@h/db` → `pgsql://u:***@h/db` |
/// | no `@`, a `:` followed by something other than a port | from that `:` to the last `@` of the text (a password holding `/`, `?` or `#`) | `pgsql://u:pa/ss@h/db` → `pgsql://u:***@h/db` |
/// | no `@`, a port | nothing | `https://h:8080/p?email=a@b` stays |
/// | no `:` | the segment before the last `@`, after the `/` before it, when it holds a `:` and no `?`, `#`, `&` or `=` | `postgres//app:secret@host` → `postgres//app:***@host` |
///
/// Masking more than the password (`mailto:***@b`) is accepted; less is
/// not. A known limit: a password of digits only followed by `/`
/// (`u:1234/5@h`) reads as a port. A URL without user info, or with a user
/// and no `:`, is returned as it is.
///
/// With [loneUserIsPassword], user info without a `:` is masked whole,
/// for schemes such as `redis://secret@host` where it is the password.
String redactUrlPassword(String url, {bool loneUserIsPassword = false}) {
  final n = url.length;
  final separator = url.indexOf('://');
  final start = separator > 0 && _isScheme(url, separator)
      ? separator + 3
      : (url.startsWith('//') ? 2 : 0);
  var end = start;
  while (end < n) {
    final c = url.codeUnitAt(end);
    if (c == 0x2f || c == 0x3f || c == 0x23) {
      break;
    }
    end++;
  }
  String masked(int from, int to) =>
      '${url.substring(0, from)}***${url.substring(to)}';

  // An `@` inside the authority.
  final at = end > start ? url.lastIndexOf('@', end - 1) : -1;
  if (at >= start) {
    final colon = url.indexOf(':', start);
    if (colon >= 0 && colon < at) {
      return masked(colon + 1, at);
    }
    return loneUserIsPassword && at > start ? masked(start, at) : url;
  }
  final last = url.lastIndexOf('@');
  if (last < end) {
    return url;
  }
  // A password holding `/`, `?` or `#`: a `:` in the authority that is not
  // a port's.
  final colon = url.indexOf(':', start);
  if (colon >= 0 && colon < end) {
    return _isPort(url, colon + 1, end) ? url : masked(colon + 1, last);
  }
  if (loneUserIsPassword) {
    return masked(start, last);
  }
  // No `:` in the authority (`postgres//app:secret@host`): the segment
  // before the last `@`, after the `/` before it.
  final segment = url.lastIndexOf('/', last - 1) + 1;
  for (var i = segment; i < last; i++) {
    final c = url.codeUnitAt(i);
    if (c == 0x3f || c == 0x23 || c == 0x26 || c == 0x3d) {
      return url;
    }
  }
  final inner = url.indexOf(':', segment);
  return inner >= 0 && inner < last ? masked(inner + 1, last) : url;
}

/// Whether `url[from, to)` is a port: one or more digits.
bool _isPort(String url, int from, int to) {
  if (from >= to) {
    return false;
  }
  for (var i = from; i < to; i++) {
    final c = url.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) {
      return false;
    }
  }
  return true;
}

/// Whether `url[0, end)` is a URL scheme (RFC 3986 §3.1): a letter, then
/// letters, digits, `+`, `-` or `.`.
bool _isScheme(String url, int end) {
  if (end == 0) {
    return false;
  }
  for (var i = 0; i < end; i++) {
    final c = url.codeUnitAt(i);
    final letter = (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a;
    if (!letter &&
        (i == 0 ||
            !((c >= 0x30 && c <= 0x39) ||
                c == 0x2b ||
                c == 0x2d ||
                c == 0x2e))) {
      return false;
    }
  }
  return true;
}

/// Names whose values logs, error messages and URLs never show: a name
/// matches when, in lower case without `-` and `_` ([normalizeKeyName]),
/// it contains one of these the same way (`X-API-KEY`, `api_key` and
/// `apiKey` are one name) — BLUEPRINT_V2 §7.6.5. The logger's default
/// `LOG_REDACT` list and [redactUrl] both use it.
const List<String> sensitiveKeyNames = <String>[
  'password',
  'passwd',
  'pwd',
  'token',
  'authorization',
  'bearer',
  'cookie',
  'secret',
  'api_key',
  'apikey',
  'jwt',
  'session_id',
  'private_key',
  'credentials',
  'dsn',
  // Pusher's auth_signature, AWS's X-Amz-Signature: a signed request
  // replayed within its window.
  'signature',
];

/// [key] in lower case without `-` and `_`, as [sensitiveKeyNames] are
/// compared.
String normalizeKeyName(String key) =>
    key.toLowerCase().replaceAll('-', '').replaceAll('_', '');

/// Whether [key] names a value to hide: its [normalizeKeyName] contains
/// one of [names], compared the same way.
bool isSensitiveKeyName(String key, [List<String> names = sensitiveKeyNames]) {
  final normalized = normalizeKeyName(key);
  return names.any((name) => normalized.contains(normalizeKeyName(name)));
}

/// Names masked in a URL only when they match whole (after
/// [normalizeKeyName]), not as part of a longer name: a SAS `sig`, an API
/// `key`, an OAuth `code`, `auth`, `pass`. `design=` and `keyword=` stay.
const Set<String> _exactUrlKeyNames = {'sig', 'key', 'code', 'auth', 'pass'};

/// [url] for messages and logs: the password in its user info masked
/// ([redactUrlPassword]), and the value of every `name=value` pair whose
/// name is sensitive replaced by `***`; other pairs stay
/// (`?token=***&page=2`).
///
/// - Pairs are everything after the first `?` or `#`, split at every `?`,
///   `&`, `;` and `#`, so the query of a URL nested in a value
///   (`?next=https://other/cb?token=…`) and a fragment of pairs (an OAuth
///   implicit-flow redirect, `#access_token=…`) are read too; a value
///   holding `://` has its own user info masked.
/// - A name is sensitive when it contains one of [names]
///   ([isSensitiveKeyName]) or is one of `sig`, `key`, `code`, `auth`,
///   `pass` whole. It is compared percent-decoded (a broken `%XX` dropped
///   first) and without control characters, so `t%00oken` and `tok%ZZen`
///   read as `token`; a pair without a raw `=` is decoded first
///   (`token%3Dvalue`).
/// - Known limits: a name encoded twice (`%2574oken`) is not recognised,
///   as a server does not read it as `token` either; a fragment without
///   `=` is left alone.
///
/// One pass over the text; like [redactUrlPassword], it needs no valid
/// URL.
String redactUrl(
  String url, {
  bool loneUserIsPassword = false,
  List<String> names = sensitiveKeyNames,
}) {
  final masked = redactUrlPassword(url, loneUserIsPassword: loneUserIsPassword);
  var first = -1;
  for (var i = 0; i < masked.length; i++) {
    final c = masked.codeUnitAt(i);
    if (c == 0x3f || c == 0x23) {
      first = i;
      break;
    }
  }
  if (first < 0) {
    return masked;
  }
  final out = StringBuffer(masked.substring(0, first + 1));
  var pairStart = first + 1;
  for (var i = first + 1; i <= masked.length; i++) {
    final c = i < masked.length ? masked.codeUnitAt(i) : -1;
    if (c == -1 || c == 0x3f || c == 0x26 || c == 0x3b || c == 0x23) {
      out.write(_maskPair(masked.substring(pairStart, i), names));
      if (c != -1) {
        out.writeCharCode(c);
      }
      pairStart = i + 1;
    }
  }
  return out.toString();
}

String _maskPair(String pair, List<String> names) {
  final equals = pair.indexOf('=');
  if (equals < 0) {
    // `token%3Dvalue`: the `=` only shows once decoded.
    final decoded = _decodedName(pair);
    final inner = decoded.indexOf('=');
    return inner > 0 && _isSensitiveUrlName(decoded.substring(0, inner), names)
        ? '${decoded.substring(0, inner)}=***'
        : pair;
  }
  final raw = pair.substring(0, equals);
  if (_isSensitiveUrlName(_decodedName(raw), names)) {
    return '$raw=***';
  }
  final value = pair.substring(equals + 1);
  return value.contains('://') ? '$raw=${redactUrlPassword(value)}' : pair;
}

bool _isSensitiveUrlName(String name, List<String> names) =>
    isSensitiveKeyName(name, names) ||
    _exactUrlKeyNames.contains(normalizeKeyName(name));

/// [raw] percent-decoded (`+` as a space), a broken `%XX` dropped first,
/// and without control characters.
String _decodedName(String raw) {
  String decoded;
  try {
    decoded = Uri.decodeQueryComponent(raw);
  } on Object {
    final kept = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final c = raw.codeUnitAt(i);
      if (c == 0x25 &&
          !(i + 2 < raw.length &&
              _isHex(raw.codeUnitAt(i + 1)) &&
              _isHex(raw.codeUnitAt(i + 2)))) {
        // A broken `%XX`: dropped with what follows it, up to two.
        i += math.min(2, raw.length - 1 - i);
        continue;
      }
      kept.writeCharCode(c);
    }
    try {
      decoded = Uri.decodeQueryComponent(kept.toString());
    } on Object {
      decoded = kept.toString();
    }
  }
  final out = StringBuffer();
  for (final c in decoded.codeUnits) {
    if (c >= 0x20 && c != 0x7f) {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);
