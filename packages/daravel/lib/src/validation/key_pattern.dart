/// The attribute patterns `distinct` and `in_array` match input keys with,
/// in one pass over the key.
library;

/// A pattern of input keys with `*` (`items.*.id`), as Laravel 13 matches
/// it:
/// - for `distinct` (`getDistinctValues`), each `*` is one key or part of
///   one: `[^.]+`, never a dot;
/// - with [crossDots], for `in_array` (`Str::is`, flags `su`), each `*` is
///   any text, dots and line breaks included: `.*`.
///
/// A regular expression of that shape backtracks on a key the client
/// writes: with two `*` and a literal tail, its time grows with the square
/// of the key's length, with three with the cube. This matcher backtracks
/// only to the last `*` it passed, so it takes time proportional to the
/// key's length times the pattern's.
final class KeyPattern {
  /// [pattern], compiled once.
  KeyPattern(String pattern, {required this.crossDots})
    : _segments = crossDots
          ? [_tokens(pattern, oneOrMore: false)]
          : [
              for (final segment in pattern.split('.'))
                _tokens(segment, oneOrMore: true),
            ];

  /// Whether a `*` takes any text (`in_array`) or one key (`distinct`).
  final bool crossDots;

  final List<List<int>> _segments;

  static const int _any = -1;
  static const int _star = -2;

  // The pattern's code units; `*` is a star, or for one key at least one
  // character and then a star (`[^.]+`).
  static List<int> _tokens(String pattern, {required bool oneOrMore}) => [
    for (final unit in pattern.codeUnits)
      if (unit == 0x2A) ...[if (oneOrMore) _any, _star] else unit,
  ];

  /// Whether the whole of [key] matches.
  bool matches(String key) {
    if (crossDots) {
      return _match(key, 0, key.length, _segments.single);
    }
    // A `*` never takes a dot, so the key's dots are the pattern's.
    var start = 0;
    for (var i = 0; i < _segments.length; i++) {
      final last = i == _segments.length - 1;
      final end = key.indexOf('.', start);
      if (last ? end >= 0 : end < 0) {
        return false;
      }
      final to = last ? key.length : end;
      if (!_match(key, start, to, _segments[i])) {
        return false;
      }
      start = to + 1;
    }
    return true;
  }

  // Wildcard matching of key[from, to) against [tokens]: on a mismatch,
  // the last star takes one more character and matching resumes after it;
  // earlier stars never need to change.
  static bool _match(String key, int from, int to, List<int> tokens) {
    var t = from;
    var p = 0;
    var starAt = -1;
    var starText = 0;
    while (t < to) {
      if (p < tokens.length && tokens[p] == _star) {
        starAt = p++;
        starText = t;
      } else if (p < tokens.length && tokens[p] == _any) {
        // One character, as PCRE's `u` reads it: a surrogate pair is one.
        p++;
        t += _isPair(key, t, to) ? 2 : 1;
      } else if (p < tokens.length && tokens[p] == key.codeUnitAt(t)) {
        p++;
        t++;
      } else if (starAt >= 0) {
        p = starAt + 1;
        t = ++starText;
      } else {
        return false;
      }
    }
    while (p < tokens.length && tokens[p] == _star) {
      p++;
    }
    return p == tokens.length;
  }

  static bool _isPair(String key, int at, int to) {
    if (at + 1 >= to) {
      return false;
    }
    final high = key.codeUnitAt(at);
    final low = key.codeUnitAt(at + 1);
    return high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF;
  }
}
