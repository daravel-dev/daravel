import 'dart:convert';

/// Attribute casting (Laravel `$casts`). [get] converts a raw database
/// value into the Dart value exposed by the model; [set] converts a Dart
/// value into what is stored.
sealed class Cast {
  const Cast();

  static const Cast integer = IntCast();
  static const Cast decimal = DoubleCast();
  static const Cast boolean = BoolCast();
  static const Cast string = StringCast();
  static const Cast dateTime = DateTimeCast();
  static const Cast date = DateCast();
  static const Cast json = JsonCast();

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
    num() => raw.toInt(),
    String() => int.tryParse(raw),
    bool() => raw ? 1 : 0,
    _ => raw,
  };
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
