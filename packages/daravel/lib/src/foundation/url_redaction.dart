import 'dart:convert';

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
/// | no `@`, a port, then a `/` and one path segment holding an `@` that does not start it | from the `:` to that `@` (a password of digits and one `/`) | `redis://my:1234/secret@h/0` → `redis://my:***@h/0` |
/// | no `@`, a port, otherwise | nothing | `https://h:8080/p?email=a@b` and `https://h:443/@user` stay |
/// | no `:` | the segment before the last `@`, after the `/` before it, when it holds a `:` and no `?`, `#`, `&` or `=` | `postgres//app:secret@host` → `postgres//app:***@host` |
///
/// Masking more than the password (`mailto:***@b`) is accepted; less is
/// not. A URL without user info, or with a user and no `:`, is returned as
/// it is.
///
/// With [loneUserIsPassword], user info without a `:` is masked whole,
/// for schemes such as `redis://secret@host` where it is the password.
///
/// The first authority `:` starts the masked password. Scheme-like text
/// inside that password is therefore included in the masked span.
///
/// Known limit: a password that starts with digits and holds a `?`, a `#`
/// or a second `/` before its `@` (`redis://my:1234/a/b@h`,
/// `pgsql://u:1234?b@h`) is not masked. RFC 3986 allows none of `/`, `?`,
/// `#` and `@` raw in user info (§3.2.1: `userinfo = *( unreserved /
/// pct-encoded / sub-delims / ":" )`) and ends the authority at the first
/// `/`, `?` or `#` (§3.2), so such a URL is a host and a port with an `@`
/// in its path, query or fragment, the same text as
/// `https://h:8080/files/a@2x.png` or `https://h:8080/p?email=a@b`, which
/// stay as they are. Percent-encode such a password (`1234%2Fa%2Fb`), as
/// the RFC requires.
String redactUrlPassword(String url, {bool loneUserIsPassword = false}) {
  final separator = url.indexOf('://');
  final start = separator > 0 && _isScheme(url, separator)
      ? separator + 3
      : (url.startsWith('//') ? 2 : 0);
  final span = _passwordSpan(
    _Text(url),
    start,
    url.length,
    loneUserIsPassword: loneUserIsPassword,
  );
  return span == null
      ? url
      : '${url.substring(0, span.$1)}***${url.substring(span.$2)}';
}

/// A text with its last `@`, read once for every URL in it.
final class _Text {
  _Text(this.value) : lastAt = value.lastIndexOf('@');

  final String value;

  /// The last `@` of [value], or -1.
  final int lastAt;

  (int, int)? _segment;
  var _segmentRead = false;

  /// The span masked in the segment before [lastAt], after the `/` before
  /// it, when it holds a `:` and no `?`, `#`, `&` or `=`: from that `:` to
  /// [lastAt]. The same for every URL of the text, so computed once.
  (int, int)? get segment {
    if (!_segmentRead) {
      _segmentRead = true;
      _segment = _segmentSpan(value, 0, lastAt);
    }
    return _segment;
  }
}

/// The span masked in the segment of `url[from, at)` before the `@` at
/// [at], after the last `/` before it: from its first `:` to [at], when it
/// holds a `:` and no `?`, `#`, `&` or `=`; else null.
(int, int)? _segmentSpan(String url, int from, int at) {
  final slash = _lastIn(url, 0x2f, from, at);
  var inner = -1;
  for (var i = slash < 0 ? from : slash + 1; i < at; i++) {
    final c = url.codeUnitAt(i);
    if (c == 0x3f || c == 0x23 || c == 0x26 || c == 0x3d) {
      return null;
    }
    if (c == 0x3a && inner < 0) {
      inner = i;
    }
  }
  return inner >= 0 ? (inner + 1, at) : null;
}

/// The span of `text.value` that [redactUrlPassword] masks for the URL
/// whose authority starts at [start], or null. Its path is read up to
/// [limit] (where the next URL of a text starts). Every scan is bounded by
/// this URL's authority or path, so the URLs of one text are read in one
/// pass.
(int, int)? _passwordSpan(
  _Text text,
  int start,
  int limit, {
  bool loneUserIsPassword = false,
}) {
  final url = text.value;
  final n = url.length;
  // The authority runs to the first `/`, `?` or `#` (RFC 3986 §3.2).
  var end = start;
  while (end < n) {
    final c = url.codeUnitAt(end);
    if (c == 0x2f || c == 0x3f || c == 0x23) {
      break;
    }
    end++;
  }
  // An `@` inside the authority.
  final at = _lastIn(url, 0x40, start, end);
  if (at >= 0) {
    final colon = _firstIn(url, 0x3a, start, at);
    if (colon >= 0) {
      return (colon + 1, at);
    }
    return loneUserIsPassword && at > start ? (start, at) : null;
  }
  final last = text.lastAt;
  if (last < end) {
    return null;
  }
  // A password holding `/`, `?` or `#`: a `:` in the authority that is not
  // a port's.
  final colon = _authorityColon(url, start, end);
  if (colon >= 0) {
    if (!_isPort(url, colon + 1, end)) {
      return (colon + 1, last);
    }
    // When a port-shaped authority continues into user info, mask through
    // that user info. Keep an ordinary `/@user` path and query `@` intact.
    if (end < limit && url.codeUnitAt(end) == 0x2f) {
      var segmentEnd = end + 1;
      while (segmentEnd < limit) {
        final c = url.codeUnitAt(segmentEnd);
        if (c == 0x2f || c == 0x3f || c == 0x23) {
          break;
        }
        segmentEnd++;
      }
      final pathAt = _firstIn(url, 0x40, end + 1, segmentEnd);
      if (pathAt > end + 1) {
        return (colon + 1, pathAt);
      }
    }
    return null;
  }
  if (start < end && url.codeUnitAt(start) == 0x5b) {
    // An unmatched IPv6 bracket is not evidence of user info.
    return null;
  }
  if (loneUserIsPassword) {
    return (start, last);
  }
  // No `:` in the authority (`postgres//app:secret@host`): the segment
  // before the last `@` of this URL (up to [limit]), after the `/` before
  // it; when this URL holds no `@`, before the last `@` of the text.
  final own = _lastIn(url, 0x40, end, limit);
  return own >= 0 ? _segmentSpan(url, end, own) : text.segment;
}

/// The first [c] in `url[from, to)`, or -1.
int _firstIn(String url, int c, int from, int to) {
  for (var i = from; i < to; i++) {
    if (url.codeUnitAt(i) == c) {
      return i;
    }
  }
  return -1;
}

/// The last [c] in `url[from, to)`, or -1.
int _lastIn(String url, int c, int from, int to) {
  for (var i = to - 1; i >= from; i--) {
    if (url.codeUnitAt(i) == c) {
      return i;
    }
  }
  return -1;
}

/// The `:` separating user info or a port in `url[start, end)`, or -1.
/// Colons inside an IPv6 literal are skipped.
int _authorityColon(String url, int start, int end) {
  if (start < end && url.codeUnitAt(start) == 0x5b) {
    final close = _firstIn(url, 0x5d, start + 1, end);
    return close < 0 ? -1 : _firstIn(url, 0x3a, close + 1, end);
  }
  return _firstIn(url, 0x3a, start, end);
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
/// - Every later `scheme://` in [url] starts a URL nested in it, in its
///   path or query (`https://proxy/r/https://u:***@h/x`), whose password
///   is masked as well ([loneUserIsPassword] applies to [url]'s own user
///   info only).
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
///   `=` is left alone. Percent-encoded nested URLs and matrix parameters
///   before the first query or fragment marker are outside pair scanning.
///
/// One pass over the text; like [redactUrlPassword], it needs no valid
/// URL.
String redactUrl(
  String url, {
  bool loneUserIsPassword = false,
  List<String> names = sensitiveKeyNames,
}) {
  final separator = url.indexOf('://');
  final start = separator > 0 && _isScheme(url, separator)
      ? separator + 3
      : (url.startsWith('//') ? 2 : 0);
  final masked = _maskPasswords(
    url,
    start,
    _urlStarts(url),
    loneUserIsPassword: loneUserIsPassword,
  );
  return _maskPairs(masked, names);
}

/// Each `scheme://` in [text]: where its scheme starts (the scheme
/// characters before `://`, from the first letter among them, so
/// `x=1pgsql://` starts at `pgsql`) and where its authority starts.
List<(int, int)> _urlStarts(String text) {
  final starts = <(int, int)>[];
  var separator = text.indexOf('://');
  while (separator >= 0) {
    var schemeStart = separator;
    while (schemeStart > 0 &&
        _isSchemeCharacter(text.codeUnitAt(schemeStart - 1))) {
      schemeStart--;
    }
    while (schemeStart < separator &&
        !_isLetter(text.codeUnitAt(schemeStart))) {
      schemeStart++;
    }
    if (schemeStart < separator) {
      starts.add((schemeStart, separator + 3));
    }
    separator = text.indexOf('://', separator + 3);
  }
  return starts;
}

/// [text] with the password masked of the URL whose authority starts at
/// [start] and of every URL in [starts] after it, each read up to the
/// next one; overlapping spans (a password running into the next URL) are
/// merged. [loneUserIsPassword] applies to the URL at [start] only. One
/// pass over [text].
String _maskPasswords(
  String text,
  int start,
  List<(int, int)> starts, {
  bool loneUserIsPassword = false,
}) {
  final scan = _Text(text);
  final later = [
    for (final s in starts)
      if (s.$2 > start) s,
  ];
  final spans = <(int, int)>[];
  void add((int, int)? span) {
    if (span != null) {
      spans.add(span);
    }
  }

  add(
    _passwordSpan(
      scan,
      start,
      later.isEmpty ? text.length : later.first.$1,
      loneUserIsPassword: loneUserIsPassword,
    ),
  );
  for (var i = 0; i < later.length; i++) {
    final limit = i + 1 < later.length ? later[i + 1].$1 : text.length;
    add(_passwordSpan(scan, later[i].$2, limit));
  }
  if (spans.isEmpty) {
    return text;
  }
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  var copied = 0;
  var i = 0;
  while (i < spans.length) {
    final from = spans[i].$1;
    var to = spans[i].$2;
    for (i++; i < spans.length && spans[i].$1 <= to; i++) {
      if (spans[i].$2 > to) {
        to = spans[i].$2;
      }
    }
    out
      ..write(text.substring(copied, from))
      ..write('***');
    copied = to;
  }
  out.write(text.substring(copied));
  return out.toString();
}

/// [masked] with the value of every sensitive pair after its first `?` or
/// `#` replaced by `***` ([redactUrl]).
String _maskPairs(String masked, List<String> names) {
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

/// Masks every URL in free-form [text], as [redactUrl] does.
///
/// The text is cut into tokens at whitespace, quotes, parentheses, braces
/// and angle brackets. In a token, every `scheme://` starts a URL whatever
/// comes before it (`a=pgsql://…;b=redis://…`, `…|…`, a URL nested in a
/// query): its password is masked as [redactUrlPassword] does, up to its
/// `@` even past the next URL. Then the pairs of the token after its first
/// `?` or `#` are masked as in [redactUrl]. Text before the first URL
/// stays. A password that runs on to an `@` of a later URL masks the text
/// between them as well: more, never less. One pass per token.
/// Percent-encoded nested URLs, matrix parameters before a query, and text
/// without a scheme remain outside the redactor's contract.
String redactUrlInText(String text, {List<String> names = sensitiveKeyNames}) {
  final out = StringBuffer();
  var start = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i != text.length && !_isTextBoundary(text.codeUnitAt(i))) {
      continue;
    }
    final token = text.substring(start, i);
    out.write(_redactTextToken(token, names));
    if (i < text.length) {
      out.writeCharCode(text.codeUnitAt(i));
    }
    start = i + 1;
  }
  return out.toString();
}

String _redactTextToken(String token, List<String> names) {
  final starts = _urlStarts(token);
  if (starts.isEmpty) {
    return token;
  }
  // Text before the first URL stays; every span lies after it.
  final first = starts.first.$1;
  final masked = _maskPasswords(token, starts.first.$2, starts);
  return '${token.substring(0, first)}'
      '${_maskPairs(masked.substring(first), names)}';
}

bool _isLetter(int c) => (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a;

bool _isSchemeCharacter(int c) {
  final letter = (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a;
  return letter ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2b ||
      c == 0x2d ||
      c == 0x2e;
}

bool _isTextBoundary(int c) =>
    c <= 0x20 ||
    c == 0x22 ||
    c == 0x27 ||
    c == 0x28 ||
    c == 0x29 ||
    c == 0x7b ||
    c == 0x7d ||
    c == 0x3c ||
    c == 0x3e;

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

bool _isSensitiveUrlName(String name, List<String> names) {
  bool matches(String value) =>
      isSensitiveKeyName(value, names) ||
      _exactUrlKeyNames.contains(normalizeKeyName(value));
  if (matches(name)) {
    return true;
  }
  final open = name.lastIndexOf('[');
  return open >= 0 &&
      name.endsWith(']') &&
      matches(name.substring(open + 1, name.length - 1));
}

/// [raw] percent-decoded (`+` as a space), a broken `%XX` dropped first,
/// and reduced to ASCII name characters. Dropping malformed Unicode and
/// punctuation makes the comparison mask more, never less.
String _decodedName(String raw) {
  final kept = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final c = raw.codeUnitAt(i);
    if (c == 0x25 &&
        !(i + 2 < raw.length &&
            _isHex(raw.codeUnitAt(i + 1)) &&
            _isHex(raw.codeUnitAt(i + 2)))) {
      // A broken `%XX`: dropped with what follows it, up to two.
      i += (raw.length - 1 - i).clamp(0, 2);
      continue;
    }
    kept.writeCharCode(c);
  }
  final decoded = Uri.decodeQueryComponent(
    kept.toString(),
    encoding: const Utf8Codec(allowMalformed: true),
  );
  final out = StringBuffer();
  for (final c in decoded.codeUnits) {
    if (_isNameCharacter(c)) {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

bool _isNameCharacter(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a) ||
    c == 0x2d ||
    c == 0x5f ||
    c == 0x5b ||
    c == 0x5d ||
    c == 0x3d;

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);
