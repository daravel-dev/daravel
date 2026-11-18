import 'dart:convert';

/// [url] with the password in its user info masked as `***`, for error
/// messages and logs: `pgsql://app:***@db/shop`.
///
/// It does not need a valid URL, so it also works on the URL a parser has
/// just rejected. The authority starts after `scheme://` (a letter, then
/// letters, digits, `+`, `-`, `.`), after a leading `//`, or else at the
/// start of the text, and runs to the first `/`, `?` or `#`. In a text of
/// several URLs ([redactUrl], [redactUrlInText]) each URL ends where the
/// next `scheme://` starts, and nothing is read or masked past that end,
/// with two exceptions: a `scheme://` that starts exactly where this URL's
/// authority starts (`redis://se://PASS@h`) is this URL's user info, and
/// row 6 joins a URL to the next one.
///
/// **The `@` that ends the user info** is the last `@` before the first
/// `/`, `?` or `#` after the first `@` the row admits; the masked span runs
/// from the first `:` the row names to it.
///
/// | Row | The URL | What is masked | Example |
/// | --- | --- | --- | --- |
/// | 1 | the authority holds an `@` | from its first `:` to its last `@` | `pgsql://u:p@ss@h/db` → `pgsql://u:***@h/db` |
/// | 2 | no `@` in the authority; a `:` followed by something other than a port (a password holding `/`, `?` or `#`) | from that `:`, admitting the first `@` of the URL | `pgsql://u:pa/ss@h/db` → `pgsql://u:***@h/db` |
/// | 3 | no `@`; a port, then `/` and one segment with an `@` after its first character and no `&`, `=` or `;` (a password of digits and one `/`) | from the `:`, admitting that `@` | `redis://my:1234/a@s@h/0` → `redis://my:***@h/0` |
/// | 4 | no `@`; a port, otherwise | nothing | `https://h:8080/p?email=a@b`, `https://h:8080/files/a@2x.png`, `https://h:443/@user` stay |
/// | 5 | no `:` in the authority | admitting the first `@` of the path (before any `?` or `#`) whose segment holds a `:` and no `&`, `=` or `;`, from that segment's first `:` | `x://h/app:s@h1/p?email=a@b` → `x://h/app:***@h1/p?email=a@b`; `postgres//app:s@host` → `postgres//app:***@host` |
/// | 6 | a row 2 password with no `@` before the next `scheme://`, whose authority holds an `@`; not when the `:` is followed by digits and then only `,`, `;`, `=`, `\|`, `&` or spaces | from the `:` to the last `@` of the next authority: the two are one URL | `redis://u:a/https://b@h` → `redis://u:***@h`; `https://h:8080\|pgsql://u:s@db` → `https://h:8080\|pgsql://u:***@db` |
///
/// Promised whole: a URL without user info, with a user and no `:`, or
/// with an `@` only in its query or fragment (`?email=a@b`), in a path
/// segment without a `:` (`/files/a@2x.png`), or in a parameter
/// (`;contact=ops@example.com`). Masking more than the password
/// (`mailto:***@b`) is accepted; less is not.
///
/// With [loneUserIsPassword], user info without a `:` is masked whole,
/// for schemes such as `redis://secret@host` where it is the password.
///
/// Known limits:
/// - A password that starts with digits and holds a `?`, a `#` or a second
///   `/` before its `@` (`redis://my:1234/a/b@h`, `pgsql://u:1234?b@h`) is
///   not masked. RFC 3986 allows none of `/`, `?`, `#` and `@` raw in user
///   info (§3.2.1: `userinfo = *( unreserved / pct-encoded / sub-delims /
///   ":" )`) and ends the authority at the first `/`, `?` or `#` (§3.2), so
///   such a URL is a host and a port with an `@` in its path, query or
///   fragment, the same text as `https://h:8080/files/a@2x.png`, which
///   stays. Percent-encode such a password (`1234%2Fa%2Fb`), as the RFC
///   requires. So is a password of digits followed by a separator and a
///   `scheme://…@` (`redis://u:1234,https://x@h`): it reads as a host and a
///   port beside another URL, and stays.
/// - A host and port with no path, then `;name=value@…`
///   (`https://h:8080;contact=ops@example.com`): the authority runs to the
///   first `/`, `?` or `#`, so this is user info `h` with the password
///   `8080;contact=ops`, and it is masked.
String redactUrlPassword(String url, {bool loneUserIsPassword = false}) {
  final separator = url.indexOf('://');
  final start = separator > 0 && _isScheme(url, separator)
      ? separator + 3
      : (url.startsWith('//') ? 2 : 0);
  final span = _passwordSpan(
    url,
    start,
    url.length,
    loneUserIsPassword: loneUserIsPassword,
  );
  return span == null
      ? url
      : '${url.substring(0, span.$1)}***${url.substring(span.$2)}';
}

/// Whether [c] is `/`, `?` or `#`, which end an authority (RFC 3986 §3.2).
bool _endsAuthority(int c) => c == 0x2f || c == 0x3f || c == 0x23;

/// Whether [c] makes a path segment a parameter rather than user info:
/// `&`, `=` or `;` (`;contact=ops@example.com`, `?email=a@b`).
bool _isParameterCharacter(int c) => c == 0x26 || c == 0x3d || c == 0x3b;

/// Where the user info whose first `@` is at [at] ends: the last `@`
/// before the first `/`, `?` or `#` after [at], within `url[at, limit)`.
int _userInfoEnd(String url, int at, int limit) {
  var last = at;
  for (var i = at + 1; i < limit; i++) {
    final c = url.codeUnitAt(i);
    if (_endsAuthority(c)) {
      break;
    }
    if (c == 0x40) {
      last = i;
    }
  }
  return last;
}

/// The span of [url] that [redactUrlPassword] masks for the URL whose
/// authority starts at [start] and which ends at [limit] (where the next
/// URL of a text starts), or null; the rows of [redactUrlPassword]'s
/// table. No scan and no span runs past [limit], so the URLs of one text
/// are read in one pass, and one URL's span never takes text of another.
(int, int)? _passwordSpan(
  String url,
  int start,
  int limit, {
  bool loneUserIsPassword = false,
}) {
  // The authority runs to the first `/`, `?` or `#` (RFC 3986 §3.2).
  var end = start;
  while (end < limit && !_endsAuthority(url.codeUnitAt(end))) {
    end++;
  }
  // Row 1: user info in the authority, up to its last `@`.
  final at = _lastIn(url, 0x40, start, end);
  if (at >= 0) {
    final colon = _firstIn(url, 0x3a, start, at);
    if (colon >= 0) {
      return (colon + 1, at);
    }
    return loneUserIsPassword && at > start ? (start, at) : null;
  }
  final colon = _authorityColon(url, start, end);
  if (colon >= 0) {
    if (!_isPort(url, colon + 1, end)) {
      // Row 2: a `:` that is not a port's, a password holding `/`, `?` or
      // `#`: up to the first `@` of this URL.
      final first = _firstIn(url, 0x40, end, limit);
      return first < 0 ? null : (colon + 1, _userInfoEnd(url, first, limit));
    }
    // Row 3: a port, then one path segment that holds an `@` after its
    // first character and no `&`, `=` or `;`.
    if (end < limit && url.codeUnitAt(end) == 0x2f) {
      for (var i = end + 1; i < limit; i++) {
        final c = url.codeUnitAt(i);
        if (_endsAuthority(c) || _isParameterCharacter(c)) {
          break;
        }
        if (c == 0x40) {
          return i > end + 1 ? (colon + 1, _userInfoEnd(url, i, limit)) : null;
        }
      }
    }
    // Row 4: a port otherwise.
    return null;
  }
  if (start < end && url.codeUnitAt(start) == 0x5b) {
    // An unmatched IPv6 bracket is not evidence of user info.
    return null;
  }
  if (loneUserIsPassword) {
    final first = _firstIn(url, 0x40, end, limit);
    return first < 0 ? null : (start, _userInfoEnd(url, first, limit));
  }
  // Row 5: no `:` in the authority. The first `@` of the path (before any
  // `?` or `#`) whose segment holds a `:` and no `&`, `=` or `;`: from
  // that `:`. One pass over the path.
  var colonInSegment = -1;
  var parameter = false;
  for (var i = end; i < limit; i++) {
    final c = url.codeUnitAt(i);
    if (c == 0x3f || c == 0x23) {
      return null;
    }
    if (c == 0x2f) {
      colonInSegment = -1;
      parameter = false;
    } else if (c == 0x40) {
      if (colonInSegment >= 0 && !parameter) {
        return (colonInSegment + 1, _userInfoEnd(url, i, limit));
      }
    } else if (c == 0x3a) {
      if (colonInSegment < 0) {
        colonInSegment = i;
      }
    } else if (_isParameterCharacter(c)) {
      parameter = true;
    }
  }
  return null;
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
/// next one. A `scheme://` that starts exactly where a URL's authority
/// starts (`redis://se://PASS@h`) is that URL's user info, not a URL of
/// its own: the URL is read on past it. [loneUserIsPassword] applies to
/// the URL at [start] only. One pass over [text].
String _maskPasswords(
  String text,
  int start,
  List<(int, int)> starts, {
  bool loneUserIsPassword = false,
}) {
  // The URLs: where each authority starts; each is read up to the scheme
  // of the next one that does not start at its own authority.
  final authorities = <int>[start];
  final limits = <int>[];
  for (final (schemeStart, authority) in starts) {
    if (authority <= start) {
      continue;
    }
    if (schemeStart == authorities.last) {
      continue; // user info of the URL before
    }
    limits.add(schemeStart);
    authorities.add(authority);
  }
  limits.add(text.length);
  final spans = <(int, int)>[];
  for (var i = 0; i < authorities.length; i++) {
    final span = _passwordSpan(
      text,
      authorities[i],
      limits[i],
      loneUserIsPassword: i == 0 && loneUserIsPassword,
    );
    if (span != null) {
      spans.add(span);
      continue;
    }
    // Row 6: this URL ends inside a row 2 password (a `:` that is not a
    // port's, no `@` before its end) and the next URL's authority holds an
    // `@`: the `scheme://` is inside the password (`redis://u:a/https://b@h`),
    // so the two are one URL, masked to that `@`.
    final colon = i + 1 < authorities.length
        ? _openPassword(text, authorities[i], limits[i])
        : -1;
    if (colon >= 0) {
      final next = authorities[i + 1];
      var end = next;
      while (end < limits[i + 1] && !_endsAuthority(text.codeUnitAt(end))) {
        end++;
      }
      final at = _lastIn(text, 0x40, next, end);
      if (at >= 0) {
        spans.add((colon + 1, at));
        i++; // the next URL is inside this password
      }
    }
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
/// query): its password is masked as [redactUrlPassword] does, within that
/// URL, which ends where the next `scheme://` starts. Then the pairs of the
/// token after its first `?` or `#` are masked as in [redactUrl]. Text
/// before the first URL stays, and so does every URL without credentials.
/// One pass per token.
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
  return value.contains('://') ? '$raw=${_maskAllPasswords(value)}' : pair;
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

/// [value] with the password of every URL in it masked, each read up to
/// the next ([_maskPasswords]): a pair value may hold several URLs.
String _maskAllPasswords(String value) {
  final separator = value.indexOf('://');
  final start = separator > 0 && _isScheme(value, separator)
      ? separator + 3
      : (value.startsWith('//') ? 2 : 0);
  return _maskPasswords(value, start, _urlStarts(value));
}

/// The `:` of a row 2 password left open at [limit] for the URL whose
/// authority starts at [start]: the authority holds no `@` and a `:` that
/// is not a port's, and no `@` follows before [limit]; else -1.
int _openPassword(String url, int start, int limit) {
  var end = start;
  while (end < limit && !_endsAuthority(url.codeUnitAt(end))) {
    end++;
  }
  if (_firstIn(url, 0x40, start, limit) >= 0) {
    return -1;
  }
  final colon = _authorityColon(url, start, end);
  if (colon < 0 || _isPort(url, colon + 1, end)) {
    return -1;
  }
  // A port and then only token separators to [limit]
  // (`https://h:8080|pgsql://…`): a host and a port, not a password.
  var i = colon + 1;
  while (i < limit && _isDigit(url.codeUnitAt(i))) {
    i++;
  }
  if (i > colon + 1) {
    while (i < limit && _isTokenSeparator(url.codeUnitAt(i))) {
      i++;
    }
    if (i == limit) {
      return -1;
    }
  }
  return colon;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Whether [c] separates URLs in one token or text: `,`, `;`, `=`, `|`,
/// `&`, or a space or control character.
bool _isTokenSeparator(int c) =>
    c <= 0x20 || c == 0x2c || c == 0x3b || c == 0x3d || c == 0x7c || c == 0x26;
