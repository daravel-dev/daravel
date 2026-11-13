/// PHP 8's comparisons of input values, as Laravel's `distinct` and
/// `in_array` make them, and an index that answers "how many of these
/// values equal this one" without comparing it with each.
///
/// Input values are what JSON or a form gives: null, a bool, an int, a
/// double, a String, or a list or map (a PHP array).
library;

import 'dart:typed_data';

/// The number of a PHP 8 numeric string (`'5'`, `' 1.5 '`, `'1e3'`,
/// `'.5'`), `null` for any other (`'0x1A'`, `'1,5'`, `'abc'`). An integer
/// beyond 64 bits is a float, as in PHP (`'99999999999999999999'` is
/// `1e20`).
///
/// Read by hand in one pass, without a regular expression: Dart's engine
/// keeps a backtracking entry for each repeat of `\d+`, so the pattern
/// used before (`^[ \t\n\r\v\f]*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?
/// \d+)?)[ \t\n\r\v\f]*$`) took 250 ms on a million digits and threw a
/// `StackOverflowError` from about 4 200 000 (`distinct` and `in_array`
/// read every value through here).
num? phpNumeric(String value) {
  final text = _phpNumericText(value);
  if (text == null) {
    return null;
  }
  var floating = false;
  for (var i = 0; i < text.length && !floating; i++) {
    final c = text.codeUnitAt(i);
    floating = c == 0x2E || c == 0x45 || c == 0x65; // . E e
  }
  return floating
      ? double.parse(text.endsWith('.') ? '${text}0' : text)
      : int.tryParse(text) ?? double.parse(text);
}

/// The number in [value] without the white space PHP allows around it
/// (space, `\t`, `\n`, `\r`, `\v`, `\f`), when the rest is
/// `[+-]?(digits[.digits?] | .digits)([eE][+-]?digits)?`; `null` otherwise.
String? _phpNumericText(String value) {
  bool space(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D);
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  final length = value.length;
  var i = 0;
  while (i < length && space(value.codeUnitAt(i))) {
    i++;
  }
  final start = i;
  if (i < length &&
      (value.codeUnitAt(i) == 0x2B || value.codeUnitAt(i) == 0x2D)) {
    i++;
  }
  final whole = i;
  while (i < length && digit(value.codeUnitAt(i))) {
    i++;
  }
  final wholeDigits = i - whole;
  var fractionDigits = 0;
  if (i < length && value.codeUnitAt(i) == 0x2E) {
    i++;
    final fraction = i;
    while (i < length && digit(value.codeUnitAt(i))) {
      i++;
    }
    fractionDigits = i - fraction;
  }
  if (wholeDigits == 0 && fractionDigits == 0) {
    return null;
  }
  if (i < length &&
      (value.codeUnitAt(i) == 0x45 || value.codeUnitAt(i) == 0x65)) {
    var j = i + 1;
    if (j < length &&
        (value.codeUnitAt(j) == 0x2B || value.codeUnitAt(j) == 0x2D)) {
      j++;
    }
    final exponent = j;
    while (j < length && digit(value.codeUnitAt(j))) {
      j++;
    }
    // An `e` without digits is not part of the number, so the string is
    // not numeric (what follows the number may only be white space).
    if (j == exponent) {
      return null;
    }
    i = j;
  }
  final end = i;
  while (i < length && space(value.codeUnitAt(i))) {
    i++;
  }
  return i == length ? value.substring(start, end) : null;
}

/// PHP 8's `==` between two numbers: two ints exactly, anything else as
/// floats (`9007199254740993 == 9007199254740992.0` is true).
bool phpNumbersEqual(num a, num b) =>
    a is int && b is int ? a == b : a.toDouble() == b.toDouble();

/// PHP's truthiness of an input value: `''`, `'0'`, `0`, `0.0` and an
/// empty list or map are false.
bool phpTruthy(Object? value) => switch (value) {
  null || false || '' || '0' => false,
  num() => value != 0,
  List<Object?>() => value.isNotEmpty,
  Map<Object?, Object?>() => value.isNotEmpty,
  _ => true,
};

/// A number as PHP's `(string)` writes it: an int in full, a float with
/// the `precision` setting's 14 significant digits (`zend_gcvt`), so `1.0`
/// is `'1'`, `0.1 + 0.2` is `'0.3'`, `-0.0` is `'-0'`, `1e14` is
/// `'1.0E+14'` and `1e-5` is `'1.0E-5'`.
String phpNumberString(num value) => switch (value) {
  final int i => '$i',
  final double d => _phpFloatString(d),
};

String _phpFloatString(double value) {
  if (value.isNaN) {
    return 'NAN';
  }
  if (value.isInfinite) {
    return value > 0 ? 'INF' : '-INF';
  }
  if (value == 0) {
    return value.isNegative ? '-0' : '0';
  }
  final (digits, point) = _significant14(value.abs());
  final sign = value < 0 ? '-' : '';
  // zend_gcvt: `point` is where the decimal point falls in the digits
  // (0.digits × 10^point); outside -3..14 the form is exponential.
  if (point < -3 || point > 14) {
    final exponent = point - 1;
    final fraction = digits.length > 1 ? digits.substring(1) : '0';
    return '$sign${digits[0]}.${fraction}E${exponent < 0 ? '-' : '+'}'
        '${exponent.abs()}';
  }
  if (point <= 0) {
    return '${sign}0.${'0' * -point}$digits';
  }
  if (digits.length <= point) {
    return '$sign$digits${'0' * (point - digits.length)}';
  }
  return '$sign${digits.substring(0, point)}.${digits.substring(point)}';
}

/// [value] (positive, finite) rounded to 14 significant digits, half to
/// even as `zend_dtoa` rounds an exact tie, trailing zeros dropped; and
/// the position of the decimal point (`value` = 0.digits × 10^point).
(String, int) _significant14(double value) {
  // The shortest digits that read back as [value]: when there are 14 or
  // fewer, rounding the exact value to 14 digits gives them too, for a
  // normal float (a subnormal one has too few bits: 5e-324 is
  // 4.9406564584125E-324).
  if (value >= 2.2250738585072014e-308) {
    final shortest = value.toStringAsExponential();
    final e = shortest.indexOf('e');
    final mantissa = shortest.substring(0, e).replaceFirst('.', '');
    if (mantissa.length <= 14) {
      return (_trimZeros(mantissa), int.parse(shortest.substring(e + 1)) + 1);
    }
  }
  // Otherwise the exact decimal expansion: value = m × 2^k exactly.
  final bits = (ByteData(8)..setFloat64(0, value)).getUint64(0);
  final biased = (bits >> 52) & 0x7ff;
  final fraction = bits & ((1 << 52) - 1);
  final m = BigInt.from(biased == 0 ? fraction : fraction | (1 << 52));
  final k = biased == 0 ? -1074 : biased - 1075;
  final (exact, scale) = k >= 0
      ? (m << k, 0)
      : (m * BigInt.from(5).pow(-k), -k);
  final text = exact.toString();
  var point = text.length - scale;
  var kept = BigInt.parse(text.substring(0, 14));
  final rest = text.substring(14);
  final half = rest.codeUnitAt(0) - 0x30;
  final beyond = rest.substring(1).split('').any((d) => d != '0');
  if (half > 5 || (half == 5 && (beyond || kept.isOdd))) {
    kept += BigInt.one;
  }
  var digits = kept.toString();
  if (digits.length > 14) {
    digits = digits.substring(0, 14);
    point++;
  }
  return (_trimZeros(digits), point);
}

String _trimZeros(String digits) {
  var end = digits.length;
  while (end > 1 && digits.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  return digits.substring(0, end);
}

/// PHP's `(string)` of a scalar input value: `true` is `'1'`, `false` and
/// `null` are `''`. Null for a list or map (PHP warns and writes `Array`).
String? phpStringForm(Object? value) => switch (value) {
  null || false => '',
  true => '1',
  final num n => phpNumberString(n),
  final String s => s,
  _ => null,
};

bool _isArray(Object? value) =>
    value is List<Object?> || value is Map<Object?, Object?>;

bool _isEmptyArray(Object? value) => switch (value) {
  final List<Object?> list => list.isEmpty,
  final Map<Object?, Object?> map => map.isEmpty,
  _ => false,
};

/// PHP 8's `==` between two input values:
/// - a bool against anything compares truthiness;
/// - null against a string is `'' == string`, against anything else
///   truthiness;
/// - numbers and numeric strings compare as numbers;
/// - a number against a non-numeric string compares the number's string;
/// - two other strings compare as text;
/// - two arrays compare key by key, loosely; an array against a number or
///   a string is never equal.
bool phpLooseEquals(Object? a, Object? b) {
  if (a is bool || b is bool) {
    return phpTruthy(a) == phpTruthy(b);
  }
  if (a == null && b == null) {
    return true;
  }
  if (a == null || b == null) {
    final other = a ?? b;
    return other is String ? other.isEmpty : !phpTruthy(other);
  }
  if (a is num && b is num) {
    return phpNumbersEqual(a, b);
  }
  if (a is String && b is String) {
    final (x, y) = (phpNumeric(a), phpNumeric(b));
    return x != null && y != null ? phpNumbersEqual(x, y) : a == b;
  }
  if (a is num && b is String) {
    final y = phpNumeric(b);
    return y != null ? phpNumbersEqual(a, y) : phpNumberString(a) == b;
  }
  if (a is String && b is num) {
    return phpLooseEquals(b, a);
  }
  if (_isArray(a) && _isArray(b)) {
    final (x, y) = (_entries(a), _entries(b));
    return x.length == y.length &&
        x.keys.every((k) => y.containsKey(k) && phpLooseEquals(x[k], y[k]));
  }
  return false;
}

/// PHP's `===` between two input values: the same type and value; arrays
/// with the same keys in the same order and identical values.
bool phpIdentical(Object? a, Object? b) => switch ((a, b)) {
  (null, null) => true,
  (final bool x, final bool y) => x == y,
  (final int x, final int y) => x == y,
  (final double x, final double y) => x == y,
  (final String x, final String y) => x == y,
  _ when _isArray(a) && _isArray(b) => () {
    final (x, y) = (_entries(a), _entries(b));
    final keys = x.keys.toList();
    return x.length == y.length &&
        keys.indexed.every(
          (e) =>
              y.keys.elementAt(e.$1) == e.$2 && phpIdentical(x[e.$2], y[e.$2]),
        );
  }(),
  _ => false,
};

Map<String, Object?> _entries(Object? array) => switch (array) {
  final List<Object?> list => {
    for (var i = 0; i < list.length; i++) '$i': list[i],
  },
  final Map<Object?, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries) '$key': value,
  },
  _ => const {},
};

/// [value] with each code point case-folded, so two strings are equal when
/// PCRE's `/iu` would match one with the other: `ſ` is `s`, the Kelvin sign
/// is `k`, `ß` stays `ß` (simple folding, never `ss`).
String phpCaseFold(String value) =>
    String.fromCharCodes([for (final rune in value.runes) _fold(rune)]);

int _fold(int rune) {
  final char = String.fromCharCode(rune);
  final upper = char.toUpperCase();
  final lower = (upper.runes.length == 1 ? upper : char).toLowerCase();
  return lower.runes.length == 1 ? lower.runes.first : rune;
}

/// How many of a fixed set of input values equal a given one, by PHP's
/// `==`, `===` or a case-insensitive string comparison, each in constant
/// time: the values are counted by kind once, as the comparison rules
/// decide them ([phpLooseEquals], [phpIdentical]).
final class PhpValueIndex {
  /// An index of [values].
  PhpValueIndex(Iterable<Object?> values) {
    for (final value in values) {
      _add(value);
    }
  }

  int _truthy = 0;
  int _falsy = 0;
  int _nulls = 0;
  int _trueBools = 0;
  int _falseBools = 0;
  int _emptyArrays = 0;
  final _NumberCounts _numbers = _NumberCounts();
  final _NumberCounts _numericStrings = _NumberCounts();
  final Map<String, int> _otherStrings = {};
  final Map<String, int> _numberForms = {};
  final List<Object?> _arrays = [];
  final Map<Object, int> _identical = {};
  Map<String, int>? _folded;
  final List<Object?> _values = [];

  void _add(Object? value) {
    _values.add(value);
    phpTruthy(value) ? _truthy++ : _falsy++;
    switch (value) {
      case null:
        _nulls++;
      case true:
        _trueBools++;
      case false:
        _falseBools++;
      case final num n:
        _numbers.add(n);
        _count(_numberForms, phpNumberString(n));
      case final String s:
        if (phpNumeric(s) case final n?) {
          _numericStrings.add(n);
        } else {
          _count(_otherStrings, s);
        }
      default:
        if (_isEmptyArray(value)) {
          _emptyArrays++;
        } else {
          _arrays.add(value);
        }
    }
    if (_identityKey(value) case final key?) {
      _count(_identical, key);
    }
  }

  static void _count<K>(Map<K, int> counts, K key) =>
      counts[key] = (counts[key] ?? 0) + 1;

  // A key equal for identical scalars only (an int is not a double; NaN
  // has none, as NaN !== NaN). Arrays other than empty have none.
  static Object? _identityKey(Object? value) => switch (value) {
    null => 'null',
    final bool b => ('bool', b),
    final int i => ('int', i),
    final double d when !d.isNaN => ('double', d),
    final String s => ('string', s),
    _ when _isEmptyArray(value) => 'emptyArray',
    _ => null,
  };

  /// How many of the values `==` [value].
  int loose(Object? value) => switch (value) {
    final bool b => b ? _truthy : _falsy,
    null =>
      _nulls +
          _falseBools +
          (_otherStrings[''] ?? 0) +
          _numbers.equal(0) +
          _emptyArrays,
    final num n =>
      (phpTruthy(n) ? _trueBools : _falseBools + _nulls) +
          _numbers.equal(n) +
          _numericStrings.equal(n) +
          (_otherStrings[phpNumberString(n)] ?? 0),
    final String s => switch (phpNumeric(s)) {
      final n? =>
        (phpTruthy(s) ? _trueBools : _falseBools) +
            _numbers.equal(n) +
            _numericStrings.equal(n),
      null =>
        (phpTruthy(s) ? _trueBools : _falseBools) +
            (s.isEmpty ? _nulls : 0) +
            (_otherStrings[s] ?? 0) +
            (_numberForms[s] ?? 0),
    },
    _ when _isEmptyArray(value) => _falseBools + _nulls + _emptyArrays,
    _ =>
      _trueBools +
          _arrays.where((other) => phpLooseEquals(value, other)).length,
  };

  /// How many of the values `===` [value].
  int identical(Object? value) => switch (_identityKey(value)) {
    final key? => _identical[key] ?? 0,
    _ => _arrays.where((other) => phpIdentical(value, other)).length,
  };

  /// How many of the values, as PHP writes them in a string, equal
  /// [value] ignoring case (`preg_grep('/^value$/iu')`). Lists and maps
  /// are never equal (PHP warns, and Laravel's request fails).
  int caseInsensitive(String value) {
    final folded = _folded ??= () {
      final counts = <String, int>{};
      for (final other in _values) {
        if (phpStringForm(other) case final form?) {
          _count(counts, phpCaseFold(form));
        }
      }
      return counts;
    }();
    return folded[phpCaseFold(value)] ?? 0;
  }
}

/// How many of a set of numbers equal one by PHP 8's `==`
/// ([phpNumbersEqual]): an int against the ints exactly and against the
/// floats as a float; a float against the floats and the ints as floats.
/// Dart's `==` between an int and a double is exact, and an int beyond
/// 2^53 is no double, so neither a `Map<num, int>` nor `==` will do.
final class _NumberCounts {
  final Map<int, int> _ints = {};
  final Map<double, int> _doubles = {};
  final Map<double, int> _intsAsDoubles = {};

  void add(num value) {
    switch (value) {
      case final int i:
        PhpValueIndex._count(_ints, i);
        PhpValueIndex._count(_intsAsDoubles, i.toDouble());
      case final double d:
        PhpValueIndex._count(_doubles, d);
    }
  }

  int equal(num value) => switch (value) {
    final int i => (_ints[i] ?? 0) + (_doubles[i.toDouble()] ?? 0),
    final double d => (_doubles[d] ?? 0) + (_intsAsDoubles[d] ?? 0),
  };
}
