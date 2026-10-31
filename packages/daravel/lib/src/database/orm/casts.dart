import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;

/// Attribute casting (Laravel `$casts`). [get] converts a raw database
/// value into the Dart value exposed by the model; [set] converts a Dart
/// value into what is stored.
sealed class Cast {
  const Cast();

  static const Cast integer = IntCast();
  static const Cast decimal = DoubleCast();

  /// Laravel's `decimal:N` cast: a string with exactly [places] decimals
  /// (`"12.50"`), rounded half up without going through a double, so
  /// `toJson` writes what Laravel writes and no precision is lost.
  static Cast decimalString(int places) => DecimalStringCast(places);

  static const Cast boolean = BoolCast();
  static const Cast string = StringCast();
  static const Cast dateTime = DateTimeCast();
  static const Cast date = DateCast();
  static const Cast json = JsonCast();

  /// Laravel's `AsVector`: a pgvector column as a `List<double>`.
  static const Cast vector = VectorCast();

  /// Laravel's `datetime:FORMAT` and `date:FORMAT` casts: the attribute
  /// reads as a [DateTime] and `Model.toJson` writes it with the PHP
  /// `date()` [format] (`'Y-m-d H:i:s'`, `'d/m/Y'`, ...), in UTC, as
  /// Laravel 8 to 13 write a formatted timestamp
  /// (`HasAttributes::addDateAttributesToArray` serializes it to UTC before
  /// `addCastAttributesToArray` formats it). The value is stored as
  /// `Y-m-d H:i:s`, like [dateTime].
  static Cast dateTimeFormat(String format) => DateTimeFormatCast(format);

  /// Casts a backed string column to an enum by `name`.
  static Cast enumeration<E extends Enum>(List<E> values) =>
      EnumCast<E>(values);

  /// A custom cast with explicit conversions.
  static Cast custom<T>({
    required T? Function(Object? raw) get,
    required Object? Function(T? value) set,
  }) => CustomCast<T>(get, set);

  Object? get(Object? raw);

  Object? set(Object? value);
}

final class IntCast extends Cast {
  const IntCast();
  @override
  Object? get(Object? raw) => switch (raw) {
    null => null,
    int() => raw,
    num() => raw.isFinite ? raw.toInt() : 0,
    String() => _fromString(raw),
    bool() => raw ? 1 : 0,
    _ => raw,
  };

  static final RegExp _numericPrefix = RegExp(
    r'^\s*[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?',
  );

  /// PHP's `(int) $string`: the leading number, truncated, or 0. A
  /// PostgreSQL `numeric` arrives as a string with decimals.
  static int _fromString(String raw) {
    final exact = int.tryParse(raw.trim());
    if (exact != null) {
      return exact;
    }
    final prefix = _numericPrefix.stringMatch(raw)?.trim();
    final number = prefix == null ? null : double.tryParse(prefix);
    return number == null || !number.isFinite ? 0 : number.toInt();
  }

  @override
  Object? set(Object? value) => get(value);
}

final class DoubleCast extends Cast {
  const DoubleCast();
  @override
  Object? get(Object? raw) => switch (raw) {
    null => null,
    num() => raw.toDouble(),
    String() => double.tryParse(raw),
    _ => raw,
  };
  @override
  Object? set(Object? value) => get(value);
}

final class DecimalStringCast extends Cast {
  const DecimalStringCast(this.places);
  final int places;

  static final RegExp _number = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$');

  @override
  Object? get(Object? raw) {
    if (raw == null) {
      return null;
    }
    final match = _number.firstMatch('$raw'.trim());
    final fraction = (match?[3] ?? '').padRight(places + 1, '0');
    if (match == null || '${match[2]}${match[3] ?? ''}'.isEmpty) {
      throw FormatException('Unable to cast value to a decimal.', raw);
    }
    final scaled =
        BigInt.parse('${match[2]}${fraction.substring(0, places)}') +
        (fraction.codeUnitAt(places) >= 0x35 ? BigInt.one : BigInt.zero);
    final digits = scaled.toString().padLeft(places + 1, '0');
    final whole = digits.substring(0, digits.length - places);
    final decimals = digits.substring(digits.length - places);
    final sign = match[1] == '-' && scaled != BigInt.zero ? '-' : '';
    return places == 0 ? '$sign$whole' : '$sign$whole.$decimals';
  }

  @override
  Object? set(Object? value) => get(value);
}

final class BoolCast extends Cast {
  const BoolCast();
  @override
  Object? get(Object? raw) => switch (raw) {
    null => null,
    bool() => raw,
    num() => raw != 0,
    '1' || 'true' || 't' => true,
    '0' || 'false' || 'f' || '' => false,
    _ => raw,
  };
  @override
  Object? set(Object? value) => switch (value) {
    null => null,
    bool() => value,
    _ => get(value),
  };
}

final class StringCast extends Cast {
  const StringCast();
  @override
  Object? get(Object? raw) => raw == null ? null : '$raw';
  @override
  Object? set(Object? value) => get(value);
}

/// `yyyy-MM-dd HH:mm:ss` in UTC (Laravel's default date format).
String formatDateTime(DateTime value) {
  final utc = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
}

/// `yyyy-MM-dd`.
String formatDate(DateTime value) {
  final utc = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}';
}

/// Parses ISO-8601, `yyyy-MM-dd HH:mm:ss` and epoch values as UTC.
DateTime? parseDateTime(Object? raw) => switch (raw) {
  null => null,
  DateTime() => raw,
  int() => DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true),
  String() => _parseStringDate(raw),
  _ => null,
};

DateTime? _parseStringDate(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return null;
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    return null;
  }
  // Values without a zone designator are stored as UTC by the framework.
  final hasZone =
      text.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(text);
  return hasZone
      ? parsed.toUtc()
      : DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
}

final class DateTimeCast extends Cast {
  const DateTimeCast();
  @override
  Object? get(Object? raw) => parseDateTime(raw);
  @override
  Object? set(Object? value) => switch (value) {
    null => null,
    DateTime() => formatDateTime(value),
    String() => value,
    _ => value,
  };
}

final class DateCast extends Cast {
  const DateCast();
  @override
  Object? get(Object? raw) {
    final parsed = parseDateTime(raw);
    return parsed == null
        ? null
        : DateTime.utc(parsed.year, parsed.month, parsed.day);
  }

  @override
  Object? set(Object? value) => switch (value) {
    null => null,
    DateTime() => formatDate(value),
    _ => value,
  };
}

/// [Cast.dateTimeFormat]: a [DateTime] attribute that `Model.toJson`
/// writes with a PHP `date()` [format].
final class DateTimeFormatCast extends Cast {
  const DateTimeFormatCast(this.format);

  /// The PHP `date()` format (`Y-m-d H:i:s`) applied by `Model.toJson`.
  final String format;

  @override
  Object? get(Object? raw) => parseDateTime(raw);

  @override
  Object? set(Object? value) => const DateTimeCast().set(value);

  /// [value] in [format], in UTC: what `toJson` writes.
  String serialize(DateTime value) => formatPhpDate(value, format);
}

const List<String> _dayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Formats [value], converted to UTC, with a PHP `date()` [format]:
/// `Y-m-d H:i:s`, `D, d M Y`, `c`, `U`, ... Every PHP token is supported,
/// `\` escapes the next character and any other character is copied.
/// Zone tokens (`e`, `T`, `O`, `P`, `p`, `Z`, `I`) describe UTC.
String formatPhpDate(DateTime value, String format) {
  final t = value.toUtc();
  final out = StringBuffer();
  String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final dayOfYear =
      DateTime.utc(
        t.year,
        t.month,
        t.day,
      ).difference(DateTime.utc(t.year)).inDays +
      1;
  // ISO-8601 week: the week of the Thursday closest to this day.
  final thursday = DateTime.utc(t.year, t.month, t.day + 4 - t.weekday);
  final isoWeek =
      thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7 + 1;
  String year(int y) => y < 0 ? '-${pad(-y, 4)}' : pad(y, 4);

  for (var i = 0; i < format.length; i++) {
    final c = format[i];
    switch (c) {
      case r'\':
        if (i + 1 < format.length) {
          out.write(format[++i]);
        }
      case 'd':
        out.write(pad(t.day));
      case 'D':
        out.write(_dayNames[t.weekday - 1].substring(0, 3));
      case 'j':
        out.write(t.day);
      case 'l':
        out.write(_dayNames[t.weekday - 1]);
      case 'N':
        out.write(t.weekday);
      case 'S':
        out.write(_ordinalSuffix(t.day));
      case 'w':
        out.write(t.weekday % 7);
      case 'z':
        out.write(dayOfYear - 1);
      case 'W':
        out.write(pad(isoWeek));
      case 'F':
        out.write(_monthNames[t.month - 1]);
      case 'm':
        out.write(pad(t.month));
      case 'M':
        out.write(_monthNames[t.month - 1].substring(0, 3));
      case 'n':
        out.write(t.month);
      case 't':
        out.write(DateTime.utc(t.year, t.month + 1, 0).day);
      case 'L':
        out.write(DateTime.utc(t.year, 2, 29).month == 2 ? 1 : 0);
      case 'o':
        out.write(year(thursday.year));
      case 'Y':
        out.write(year(t.year));
      case 'y':
        out.write(pad(t.year % 100));
      case 'a':
        out.write(t.hour < 12 ? 'am' : 'pm');
      case 'A':
        out.write(t.hour < 12 ? 'AM' : 'PM');
      case 'B':
        final beat =
            ((t.hour * 3600 + t.minute * 60 + t.second + 3600) / 86.4).floor() %
            1000;
        out.write(pad(beat, 3));
      case 'g':
        out.write(hour12);
      case 'G':
        out.write(t.hour);
      case 'h':
        out.write(pad(hour12));
      case 'H':
        out.write(pad(t.hour));
      case 'i':
        out.write(pad(t.minute));
      case 's':
        out.write(pad(t.second));
      case 'u':
        out.write(pad(t.millisecond * 1000 + t.microsecond, 6));
      case 'v':
        out.write(pad(t.millisecond, 3));
      case 'e' || 'T':
        out.write('UTC');
      case 'I' || 'Z':
        out.write('0');
      case 'O':
        out.write('+0000');
      case 'P':
        out.write('+00:00');
      case 'p':
        out.write('Z');
      case 'c':
        out.write(formatPhpDate(t, r'Y-m-d\TH:i:sP'));
      case 'r':
        out.write(formatPhpDate(t, 'D, d M Y H:i:s O'));
      case 'U':
        out.write((t.millisecondsSinceEpoch / 1000).floor());
      default:
        out.write(c);
    }
  }
  return out.toString();
}

String _ordinalSuffix(int day) {
  if (day >= 11 && day <= 13) {
    return 'th';
  }
  return switch (day % 10) {
    1 => 'st',
    2 => 'nd',
    3 => 'rd',
    _ => 'th',
  };
}

final class VectorCast extends Cast {
  const VectorCast();

  @override
  Object? get(Object? raw) => switch (raw) {
    null => null,
    String() => [
      for (final value in jsonDecode(raw) as List<Object?>)
        (value! as num).toDouble(),
    ],
    final List<Object?> values => [
      for (final value in values) (value! as num).toDouble(),
    ],
    // The driver cannot name an extension's type: its OID differs per database.
    final pg.UndecodedBytes bytes when bytes.isBinary => _binary(bytes.bytes),
    final pg.UndecodedBytes text => get(text.asString),
    _ => throw ArgumentError.value(raw, 'raw', 'Not a vector'),
  };

  /// pgvector's binary form: dimensions, a reserved field, then floats.
  static List<double> _binary(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i < data.getUint16(0); i++)
        _shortest(data.getFloat32(4 + i * 4)),
    ];
  }

  /// The shortest decimal that is this `float4`, which is what pgvector prints
  /// and Laravel reads: 0.9, not 0.8999999761581421.
  static double _shortest(double value) {
    final float = Float32List(1);
    for (var digits = 1; digits < 9; digits++) {
      final candidate = double.parse(value.toStringAsPrecision(digits));
      float[0] = candidate;
      if (float[0] == value) {
        return candidate;
      }
    }
    return value;
  }

  @override
  Object? set(Object? value) => switch (value) {
    null => null,
    final Iterable<num> values => jsonEncode([
      for (final item in values) item.toDouble(),
    ]),
    _ => throw ArgumentError.value(
      value,
      'value',
      'Expected a list of numbers',
    ),
  };
}

final class JsonCast extends Cast {
  const JsonCast();
  @override
  Object? get(Object? raw) => switch (raw) {
    null => null,
    String() => raw.isEmpty ? null : jsonDecode(raw),
    _ => raw,
  };
  @override
  Object? set(Object? value) => switch (value) {
    null => null,
    String() => value,
    _ => jsonEncode(value),
  };
}

final class EnumCast<E extends Enum> extends Cast {
  const EnumCast(this.values);
  final List<E> values;
  @override
  Object? get(Object? raw) {
    if (raw == null || raw is E) {
      return raw;
    }
    for (final value in values) {
      if (value.name == '$raw') {
        return value;
      }
    }
    return null;
  }

  @override
  Object? set(Object? value) => value is Enum ? value.name : value;
}

final class CustomCast<T> extends Cast {
  const CustomCast(this._get, this._set);
  final T? Function(Object? raw) _get;
  final Object? Function(T? value) _set;
  @override
  Object? get(Object? raw) => _get(raw);
  @override
  Object? set(Object? value) => _set(value as T?);
}
