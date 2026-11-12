/// PHP's `filter_var($value, FILTER_VALIDATE_EMAIL)`, with and without
/// `FILTER_FLAG_EMAIL_UNICODE`, as one pass over the address instead of
/// PHP's regex.
///
/// PHP checks the address with a regex (ext/filter/logical_filters.c,
/// `php_filter_validate_email`, based on one by Michael Rushton: "Copyright
/// © Michael Rushton 2009-10 http://squiloople.com/ Feel free to use and
/// redistribute this code. But please keep this copyright notice."). Its
/// two leading lookaheads backtrack exponentially: PCRE gives up at its
/// backtrack limit and PHP answers `false`, but Dart's regex engine has no
/// limit, so `'"a' * 22 + '"@example.com'` took 18 s and 100 characters do
/// not finish. This file reads the same language without backtracking.
///
/// What the regex says, part by part (PHP 8.3, flags `/iD`, and `/iDu` with
/// `\pL\pN` added to the local part's characters for the unicode variant):
/// - at most 320 octets, checked before the regex;
/// - `(?!(?:unit){255,})` and `(?!(?:unit){65,}@)`, where a unit is
///   `"? (\ [\x00-\x7E] | [^\\"]) "?`: counts, see [_unitLimits];
/// - the local part: dot-separated atoms (`[\x21\x23-\x27\x2A\x2B\x2D
///   \x2F-\x39\x3D\x3F\x5E-\x7E]+`) or quoted strings (`"` then
///   `[\x01-\x08\x0B\x0C\x0E-\x1F\x21\x23-\x5B\x5D-\x7F]` or `\` with an
///   ASCII character, then `"`);
/// - `@`, then a host name (labels of letters, digits and inner hyphens, no
///   run of 64 characters without a dot, a last label starting with a
///   letter) or a domain literal (`[` IPv4, IPv6 or IPv6 with an IPv4 tail
///   `]`).
///
/// `/i` makes letters match either case; with `/u` PCRE also folds `ſ`
/// (U+017F) to `s` and the Kelvin sign (U+212A) to `k`, so they match the
/// ASCII ranges that hold `s` and `k`.
library;

import 'dart:convert';

/// Whether PHP's `filter_var($value, FILTER_VALIDATE_EMAIL)` accepts
/// [value]; with [unicode], with `FILTER_FLAG_EMAIL_UNICODE`. Linear in the
/// length of [value].
bool phpFilterEmail(String value, {bool unicode = false}) {
  final codes = <int>[];
  for (final rune in value.runes) {
    // A lone surrogate is not UTF-8: PCRE refuses the subject in /u mode,
    // and without /u it is not ASCII.
    if (rune >= 0xD800 && rune <= 0xDFFF) {
      return false;
    }
    // Without /u, PCRE reads bytes; no part of the address accepts one
    // above 0x7F.
    if (!unicode && rune > 0x7F) {
      return false;
    }
    codes.add(rune);
  }
  if (utf8.encode(value).length > 320) {
    return false;
  }
  return _EmailFilter(codes, unicode).valid();
}

const int _quote = 0x22;
const int _backslash = 0x5C;
const int _at = 0x40;
const int _dot = 0x2E;
const int _hyphen = 0x2D;

final class _EmailFilter {
  _EmailFilter(this.s, this.unicode);

  final List<int> s;
  final bool unicode;

  static final RegExp _letterOrNumber = RegExp(
    r'^[\p{L}\p{N}]$',
    unicode: true,
  );

  int at(int i) => i < s.length ? s[i] : -1;

  bool valid() => !_unitLimits() && _address();

  /// The two lookaheads. A unit is one character other than `\` and `"`,
  /// or `\` with a character up to 0x7E, with at most one `"` on each side.
  /// Which characters are units is fixed; only the quotes move. A run of
  /// quotes ends the units when no unit can take it: more than one before
  /// the first, more than two between two others. The address fails when
  /// 255 units can be read from its start, or 65 followed by `@` (after
  /// the 65th or a later unit, possibly behind one quote it takes).
  bool _unitLimits() {
    var units = 0;
    var i = 0;
    while (true) {
      var quotes = 0;
      while (at(i) == _quote) {
        quotes++;
        i++;
      }
      if (quotes > (units == 0 ? 1 : 2) || i >= s.length) {
        return false;
      }
      if (s[i] == _backslash) {
        if (i + 1 >= s.length || !_inRange(s[i + 1], 0x00, 0x7E)) {
          return false;
        }
        i += 2;
      } else {
        i += 1;
      }
      units++;
      if (units >= 255) {
        return true;
      }
      if (units >= 65 &&
          (at(i) == _at || (at(i) == _quote && at(i + 1) == _at))) {
        return true;
      }
    }
  }

  bool _address() {
    var i = 0;
    // The local part: words separated by dots, then `@`.
    while (true) {
      if (at(i) == _quote) {
        i++;
        while (true) {
          final c = at(i);
          if (c == -1) {
            return false;
          }
          if (c == _quote) {
            i++;
            break;
          }
          if (c == _backslash) {
            if (i + 1 >= s.length || !_inRange(s[i + 1], 0x00, 0x7F)) {
              return false;
            }
            i += 2;
          } else if (_quotedText(c)) {
            i++;
          } else {
            return false;
          }
        }
      } else {
        final start = i;
        while (i < s.length && _atomText(s[i])) {
          i++;
        }
        if (i == start) {
          return false;
        }
      }
      if (at(i) == _dot) {
        i++;
        continue;
      }
      break;
    }
    if (at(i) != _at) {
      return false;
    }
    final domain = s.sublist(i + 1);
    return _hostName(domain) || _domainLiteral(domain);
  }

  bool _atomText(int c) =>
      c == 0x21 ||
      _inRange(c, 0x23, 0x27) ||
      c == 0x2A ||
      c == 0x2B ||
      c == 0x2D ||
      _inRange(c, 0x2F, 0x39) ||
      c == 0x3D ||
      c == 0x3F ||
      _inRange(c, 0x5E, 0x7E) ||
      _letterOrNumberIfUnicode(c);

  bool _quotedText(int c) =>
      _inRange(c, 0x01, 0x08) ||
      c == 0x0B ||
      c == 0x0C ||
      _inRange(c, 0x0E, 0x1F) ||
      c == 0x21 ||
      _inRange(c, 0x23, 0x5B) ||
      _inRange(c, 0x5D, 0x7F) ||
      _letterOrNumberIfUnicode(c);

  bool _letterOrNumberIfUnicode(int c) =>
      unicode && c > 0x7F && _letterOrNumber.hasMatch(String.fromCharCode(c));

  /// `[lo-hi]` under `/i` (and `/u`): [c] or one of its case variants is in
  /// the range.
  bool _inRange(int c, int lo, int hi) {
    bool inside(int x) => x >= lo && x <= hi;
    if (inside(c)) {
      return true;
    }
    if (c >= 0x41 && c <= 0x5A) {
      return inside(c + 0x20);
    }
    if (c >= 0x61 && c <= 0x7A) {
      return inside(c - 0x20);
    }
    if (unicode && c == 0x017F) {
      return inside(0x73) || inside(0x53);
    }
    if (unicode && c == 0x212A) {
      return inside(0x6B) || inside(0x4B);
    }
    return false;
  }

  bool _alnum(int c) => _inRange(c, 0x61, 0x7A) || _inRange(c, 0x30, 0x39);

  /// Labels of `[a-z0-9]+(-+[a-z0-9]+)*` each followed by a dot, at least
  /// one, then a last label of `[a-z][a-z0-9]*(-+[a-z0-9]+)*` (the regex's
  /// optional `xn--` prefixes add nothing to these), and no run of 64
  /// characters without a dot (`(?!.*[^.]{64,})`).
  bool _hostName(List<int> d) {
    var run = 0;
    for (final c in d) {
      run = c == _dot ? 0 : run + 1;
      if (run >= 64) {
        return false;
      }
    }
    final labels = <List<int>>[[]];
    for (final c in d) {
      if (c == _dot) {
        labels.add([]);
      } else {
        labels.last.add(c);
      }
    }
    if (labels.length < 2) {
      return false;
    }
    for (var n = 0; n < labels.length; n++) {
      final label = labels[n];
      if (label.isEmpty || !_alnum(label.first) || !_alnum(label.last)) {
        return false;
      }
      if (!label.every((c) => c == _hyphen || _alnum(c))) {
        return false;
      }
    }
    return _inRange(labels.last.first, 0x61, 0x7A);
  }

  /// `[` IPv4 `]`, or `[IPv6:` the address `]`: eight groups, or `::`
  /// with at most six groups around it, or an IPv4 tail after six groups
  /// or after `::` with at most four groups around it.
  bool _domainLiteral(List<int> d) {
    if (d.length < 2 || d.first != 0x5B || d.last != 0x5D) {
      return false;
    }
    final content = d.sublist(1, d.length - 1);
    if (_ipv4(content)) {
      return true;
    }
    const prefix = [0x69, 0x70, 0x76, 0x36, 0x3A]; // ipv6:
    if (content.length < prefix.length) {
      return false;
    }
    for (var i = 0; i < prefix.length; i++) {
      final c = content[i];
      final lower = c >= 0x41 && c <= 0x5A ? c + 0x20 : c;
      if (lower != prefix[i]) {
        return false;
      }
    }
    final rest = content.sublist(prefix.length);
    if (_groups(rest, 8, 8)) {
      return true;
    }
    // (?!(?:.*[a-f0-9][:\]]){7,}), over the rest of the subject: the
    // address and the closing bracket.
    if (_hexBefore([...rest, 0x5D], const {0x3A, 0x5D}) < 7 &&
        _compressed(rest, 6, tail: false)) {
      return true;
    }
    final colon = rest.lastIndexOf(0x3A);
    if (colon < 0 || !_ipv4(rest.sublist(colon + 1))) {
      return false;
    }
    final head = rest.sublist(0, colon + 1);
    if (_groups(head.sublist(0, head.length - 1), 6, 6)) {
      return true;
    }
    // (?!(?:.*[a-f0-9]:){5,})
    return _hexBefore(rest, const {0x3A}) < 5 &&
        _compressed(head, 4, tail: true);
  }

  /// How many hexadecimal digits are followed by one of [next].
  int _hexBefore(List<int> text, Set<int> next) {
    var count = 0;
    for (var i = 0; i + 1 < text.length; i++) {
      if (_hex(text[i]) && next.contains(text[i + 1])) {
        count++;
      }
    }
    return count;
  }

  /// `(h16(:h16){0,max-1})?::(h16(:h16){0,max-1})?`; with [tail], the
  /// part after `::` is `(h16(:h16){0,max-1}:)?` instead.
  bool _compressed(List<int> text, int max, {required bool tail}) {
    var split = -1;
    for (var i = 0; i + 1 < text.length; i++) {
      if (text[i] == 0x3A && text[i + 1] == 0x3A) {
        split = i;
        break;
      }
    }
    if (split < 0) {
      return false;
    }
    final left = text.sublist(0, split);
    var right = text.sublist(split + 2);
    if (left.isNotEmpty && !_groups(left, 1, max)) {
      return false;
    }
    if (right.isEmpty) {
      return true;
    }
    if (tail) {
      if (right.last != 0x3A) {
        return false;
      }
      right = right.sublist(0, right.length - 1);
    }
    return _groups(right, 1, max);
  }

  /// [text] is `min` to `max` groups of one to four hexadecimal digits
  /// separated by `:`.
  bool _groups(List<int> text, int min, int max) {
    var groups = 1;
    var digits = 0;
    for (final c in text) {
      if (c == 0x3A) {
        if (digits == 0) {
          return false;
        }
        groups++;
        digits = 0;
      } else if (_hex(c) && digits < 4) {
        digits++;
      } else {
        return false;
      }
    }
    return digits > 0 && groups >= min && groups <= max;
  }

  bool _hex(int c) => _inRange(c, 0x61, 0x66) || _inRange(c, 0x30, 0x39);

  /// Four dot-separated numbers from 0 to 255 without leading zeros
  /// (`25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]`).
  bool _ipv4(List<int> text) {
    var parts = 0;
    var start = 0;
    for (var i = 0; i <= text.length; i++) {
      if (i < text.length && text[i] != _dot) {
        continue;
      }
      final part = text.sublist(start, i);
      if (part.isEmpty ||
          part.length > 3 ||
          !part.every((c) => c >= 0x30 && c <= 0x39) ||
          (part.length > 1 && part.first == 0x30) ||
          int.parse(String.fromCharCodes(part)) > 255) {
        return false;
      }
      parts++;
      start = i + 1;
    }
    return parts == 4;
  }
}
