import '../database/orm/casts.dart' show formatPhpDate;

/// Laravel's `date_format` check (`ValidatesAttributes::validateDateFormat`,
/// laravel/framework v8.83.27 to v13.38.0): [value] passes when PHP's
/// `DateTime::createFromFormat('!' . $format, $value, UTC)` reads it and
/// formatting the result with [format] gives [value] back exactly, so
/// `2026-02-30` fails `Y-m-d` (it overflows to March) and `2026-1-5` fails
/// `Y-m-d` but passes `Y-n-j`.
///
/// The format tokens are PHP's `DateTimeImmutable::createFromFormat` ones:
/// `d j D l S z F M m n Y y a A g G h H i s v u e T O P p U`, `\` escapes,
/// `?` any byte, `*` any run up to a separator, `+` trailing data, `!` and
/// `|` reset. A zone name such as `Asia/Jakarta` is accepted as written but
/// not resolved, so it only round-trips through `e`/`T`.
bool phpDateMatchesFormat(String value, String format) {
  final parsed = _parse(value, format);
  if (parsed == null) {
    return false;
  }
  return _format(parsed, format) == value;
}

final class _Parsed {
  int year = 1970;
  int month = 1;
  int day = 1;
  int hour = 0;
  int minute = 0;
  int second = 0;
  int microsecond = 0;
  int? dayOfYear;
  bool? pm;
  int? epoch;

  /// Offset in seconds when a numeric zone was read.
  int offset = 0;

  /// The zone as written (`e`, `T`), echoed back by [_format].
  String? zoneText;
}

const List<String> _months = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];

_Parsed? _parse(String value, String format) {
  final p = _Parsed();
  var i = 0;

  int? digits(int min, int max) {
    var j = i;
    while (j < value.length && j - i < max && _isDigit(value.codeUnitAt(j))) {
      j++;
    }
    if (j - i < min) {
      return null;
    }
    final n = int.parse(value.substring(i, j));
    i = j;
    return n;
  }

  String? letters() {
    var j = i;
    while (j < value.length && _isLetter(value.codeUnitAt(j))) {
      j++;
    }
    if (j == i) {
      return null;
    }
    final word = value.substring(i, j);
    i = j;
    return word;
  }

  for (var f = 0; f < format.length; f++) {
    final c = format[f];
    switch (c) {
      case 'd' || 'j':
        final n = digits(1, 2);
        if (n == null) return null;
        p.day = n;
      case 'D' || 'l':
        if (letters() == null) return null;
      case 'S':
        if (i + 2 > value.length) return null;
        i += 2;
      case 'z':
        final n = digits(1, 3);
        if (n == null) return null;
        p.dayOfYear = n;
      case 'F' || 'M':
        final word = letters()?.toLowerCase();
        if (word == null) return null;
        final index = _months.indexWhere(
          (m) => m == word || (word.length == 3 && m.startsWith(word)),
        );
        if (index < 0) return null;
        p.month = index + 1;
      case 'm' || 'n':
        final n = digits(1, 2);
        if (n == null) return null;
        p.month = n;
      case 'Y':
        final negative = i < value.length && value[i] == '-';
        if (negative) i++;
        final n = digits(1, 4);
        if (n == null) return null;
        p.year = negative ? -n : n;
      case 'y':
        final n = digits(2, 2);
        if (n == null) return null;
        p.year = n < 70 ? 2000 + n : 1900 + n;
      case 'a' || 'A':
        if (i + 2 > value.length) return null;
        final word = value.substring(i, i + 2).toLowerCase();
        if (word != 'am' && word != 'pm') return null;
        p.pm = word == 'pm';
        i += 2;
      case 'g' || 'h' || 'G' || 'H':
        final n = digits(1, 2);
        if (n == null) return null;
        p.hour = n;
      case 'i':
        final n = digits(2, 2);
        if (n == null) return null;
        p.minute = n;
      case 's':
        final n = digits(2, 2);
        if (n == null) return null;
        p.second = n;
      case 'v':
        final n = digits(3, 3);
        if (n == null) return null;
        p.microsecond = n * 1000;
      case 'u':
        final start = i;
        final n = digits(1, 6);
        if (n == null) return null;
        p.microsecond = n * _pow10(6 - (i - start));
      case 'e' || 'T' || 'O' || 'P' || 'p':
        final zone = _readZone(value, i);
        if (zone == null) return null;
        i = zone.end;
        p.offset = zone.offset ?? p.offset;
        p.zoneText = zone.text;
      case 'U':
        final negative = i < value.length && value[i] == '-';
        if (negative) i++;
        final n = digits(1, 19);
        if (n == null) return null;
        p.epoch = negative ? -n : n;
      case '!' || '|':
        break;
      case '?':
        if (i >= value.length) return null;
        i++;
      case '*':
        while (i < value.length && !_isSeparator(value[i])) {
          i++;
        }
      case '+':
        i = value.length;
      case '#':
        if (i >= value.length || !';:/.,-()'.contains(value[i])) return null;
        i++;
      case r'\':
        if (f + 1 >= format.length) return null;
        f++;
        if (i >= value.length || value[i] != format[f]) return null;
        i++;
      default:
        if (i >= value.length || value[i] != c) return null;
        i++;
    }
  }
  if (i != value.length) {
    return null; // Trailing data: createFromFormat returns false.
  }
  if (p.pm != null) {
    if (p.hour < 1 || p.hour > 12) return null;
    p.hour = p.hour % 12 + (p.pm! ? 12 : 0);
  }
  return p;
}

DateTime _wall(_Parsed p) {
  if (p.epoch case final epoch?) {
    return DateTime.fromMillisecondsSinceEpoch(
      epoch * 1000,
      isUtc: true,
    ).add(Duration(seconds: p.offset));
  }
  if (p.dayOfYear case final day?) {
    return DateTime.utc(
      p.year,
      1,
      1 + day,
      p.hour,
      p.minute,
      p.second,
      0,
      p.microsecond,
    );
  }
  return DateTime.utc(
    p.year,
    p.month,
    p.day,
    p.hour,
    p.minute,
    p.second,
    0,
    p.microsecond,
  );
}

/// Formats [p] as PHP's `DateTime::format` would: wall-clock fields in the
/// zone that was read, zone tokens printing that zone.
String _format(_Parsed p, String format) {
  final wall = _wall(p);
  final sign = p.offset < 0 ? '-' : '+';
  final hours = (p.offset.abs() ~/ 3600).toString().padLeft(2, '0');
  final minutes = (p.offset.abs() % 3600 ~/ 60).toString().padLeft(2, '0');
  String escape(String text) => text.split('').map((c) => '\\$c').join();
  final zone = <String, String>{
    'O': '$sign$hours$minutes',
    'P': '$sign$hours:$minutes',
    'p': p.offset == 0 ? 'Z' : '$sign$hours:$minutes',
    'e': p.zoneText ?? 'UTC',
    'T': p.zoneText ?? 'UTC',
    'Z': '${p.offset}',
    'U': '${(wall.millisecondsSinceEpoch ~/ 1000) - p.offset}',
  };
  final out = StringBuffer();
  for (var f = 0; f < format.length; f++) {
    final c = format[f];
    if (c == r'\' && f + 1 < format.length) {
      out
        ..write(c)
        ..write(format[++f]);
    } else if (c == 'c') {
      out.write(r'Y-m-d\TH:i:s');
      out.write(escape(zone['P']!));
    } else if (c == 'r') {
      out.write('D, d M Y H:i:s ');
      out.write(escape(zone['O']!));
    } else if (zone[c] case final text?) {
      out.write(escape(text));
    } else if (c == '!' ||
        c == '|' ||
        c == '+' ||
        c == '*' ||
        c == '?' ||
        c == '#') {
      // Parse-only tokens print nothing.
    } else {
      out.write(c);
    }
  }
  return formatPhpDate(wall, out.toString());
}

({int end, int? offset, String text})? _readZone(String value, int start) {
  final rest = value.substring(start);
  if (rest.startsWith('Z')) {
    return (end: start + 1, offset: 0, text: 'Z');
  }
  final numeric = RegExp(r'^([+-])(\d{2}):?(\d{2})').firstMatch(rest);
  if (numeric != null) {
    final seconds = int.parse(numeric[2]!) * 3600 + int.parse(numeric[3]!) * 60;
    return (
      end: start + numeric[0]!.length,
      offset: numeric[1] == '-' ? -seconds : seconds,
      text: numeric[0]!,
    );
  }
  final name = RegExp(r'^[A-Za-z][A-Za-z_/+-]*').firstMatch(rest);
  if (name == null) {
    return null;
  }
  final text = name[0]!;
  final upper = text.toUpperCase();
  return (
    end: start + text.length,
    offset: upper == 'UTC' || upper == 'GMT' || upper == 'Z' ? 0 : null,
    text: text,
  );
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

bool _isLetter(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

bool _isSeparator(String c) => ' ,;:/.-()'.contains(c);

int _pow10(int n) {
  var result = 1;
  for (var k = 0; k < n; k++) {
    result *= 10;
  }
  return result;
}
