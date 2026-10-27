import 'dart:convert';

/// How [RedisStore] writes values that are not numbers
/// (`REDIS_SERIALIZER`). Both are always read.
enum RedisSerializer {
  /// JSON, readable from any language.
  json,

  /// PHP's `serialize()`, as Laravel's cache writes and reads it, so both
  /// frameworks share cached values.
  php,
}

/// PHP's `serialize()` and `unserialize()` for the values JSON can hold:
/// `null`, booleans, numbers, strings, lists and maps (PHP arrays).
///
/// Reading also takes PHP objects (`O:`), as maps of their properties
/// (private and protected ones by their bare names), and enums (`E:`), as
/// `Class:Case` strings. Lengths count UTF-8 bytes, as PHP does.
abstract final class PhpSerializer {
  /// [value] as `serialize($value)` writes it; anything that is not JSON
  /// is first turned into JSON's values (`toJson()`).
  static String encode(Object? value) {
    final out = StringBuffer();
    _write(out, _plain(value));
    return out.toString();
  }

  static Object? _plain(Object? value) => switch (value) {
    null || bool() || num() || String() => value,
    final List<Object?> list => [for (final item in list) _plain(item)],
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) key: _plain(value),
    },
    _ => jsonDecode(jsonEncode(value)),
  };

  static void _write(StringBuffer out, Object? value) {
    switch (value) {
      case null:
        out.write('N;');
      case final bool flag:
        out.write('b:${flag ? 1 : 0};');
      case final int number:
        out.write('i:$number;');
      case final double number:
        out.write('d:${_double(number)};');
      case final String text:
        out.write('s:${utf8.encode(text).length}:"$text";');
      case final List<Object?> list:
        out.write('a:${list.length}:{');
        for (var i = 0; i < list.length; i++) {
          out.write('i:$i;');
          _write(out, list[i]);
        }
        out.write('}');
      case final Map<Object?, Object?> map:
        out.write('a:${map.length}:{');
        for (final MapEntry(:key, :value) in map.entries) {
          _write(out, key is int ? key : '$key');
          _write(out, value);
        }
        out.write('}');
      default:
        throw ArgumentError.value(value, 'value', 'cannot be serialized');
    }
  }

  static String _double(double number) {
    if (number.isNaN) {
      return 'NAN';
    }
    if (number.isInfinite) {
      return number > 0 ? 'INF' : '-INF';
    }
    // PHP writes 1.0 as 1 (serialize_precision -1) and 1e21 as 1.0E+21.
    final text = number.toString();
    final e = text.indexOf('e');
    if (e >= 0) {
      final mantissa = text.substring(0, e);
      return '${mantissa.contains('.') ? mantissa : '$mantissa.0'}'
          'E${text.substring(e + 1)}';
    }
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  /// Whether [raw] starts as `serialize()` output does.
  static bool looksSerialized(String raw) =>
      raw == 'N;' || RegExp(r'^[bidsaOE]:').hasMatch(raw);

  /// The value `serialize()` wrote in [raw]; [FormatException] when it is
  /// not one (or uses what Daravel cannot read: references, `C:` classes).
  static Object? decode(String raw) {
    final reader = _Reader(utf8.encode(raw));
    final value = reader.value();
    if (reader.offset != reader.bytes.length) {
      throw const FormatException('Trailing bytes after a PHP value.');
    }
    return value;
  }
}

final class _Reader {
  _Reader(this.bytes);

  final List<int> bytes;
  int offset = 0;

  Never _fail(String message) => throw FormatException(message, null, offset);

  int _byte() =>
      offset < bytes.length ? bytes[offset++] : _fail('Unexpected end.');

  void _expect(int byte) {
    if (_byte() != byte) {
      _fail('Expected "${String.fromCharCode(byte)}".');
    }
  }

  /// Text up to [end], which is consumed.
  String _until(int end) {
    final start = offset;
    while (offset < bytes.length && bytes[offset] != end) {
      offset++;
    }
    if (offset >= bytes.length) {
      _fail('Unexpected end.');
    }
    return utf8.decode(bytes.sublist(start, offset++));
  }

  int _int(int end) =>
      int.tryParse(_until(end)) ?? _fail('Expected an integer.');

  String _string() {
    final length = _int(0x3a); // s:<length>:"...";
    _expect(0x22);
    if (offset + length > bytes.length) {
      _fail('String longer than the value.');
    }
    final text = utf8.decode(bytes.sublist(offset, offset + length));
    offset += length;
    _expect(0x22);
    return text;
  }

  Object? value() {
    final type = _byte();
    if (type == 0x4e) {
      // N;
      _expect(0x3b);
      return null;
    }
    _expect(0x3a);
    switch (type) {
      case 0x62: // b:1;
        return _int(0x3b) == 1;
      case 0x69: // i:42;
        return _int(0x3b);
      case 0x64: // d:0.5;
        final text = _until(0x3b);
        return switch (text) {
          'NAN' => double.nan,
          'INF' => double.infinity,
          '-INF' => double.negativeInfinity,
          _ => double.tryParse(text) ?? _fail('Expected a number.'),
        };
      case 0x73: // s:5:"hello";
        final text = _string();
        _expect(0x3b);
        return text;
      case 0x61: // a:2:{...}
        return _array(_int(0x3a));
      case 0x4f: // O:8:"stdClass":1:{...}
        _string();
        _expect(0x3a);
        final properties = _array(_int(0x3a));
        return properties is Map<String, Object?>
            ? properties
            : <String, Object?>{
                for (final (i, item) in (properties as List).indexed)
                  '$i': item,
              };
      case 0x45: // E:11:"Suit:Hearts";
        final name = _string();
        _expect(0x3b);
        return name;
    }
    _fail('Unsupported PHP type "${String.fromCharCode(type)}".');
  }

  /// `{key value ...}`: a list when its keys are 0, 1, 2..., else a map
  /// (an object's `\0Class\0name` and `\0*\0name` keys by their names).
  Object _array(int count) {
    _expect(0x7b);
    final entries = <Object?, Object?>{};
    for (var i = 0; i < count; i++) {
      final key = value();
      entries[key is String ? _property(key) : key] = value();
    }
    _expect(0x7d);
    final keys = entries.keys.toList();
    final isList = [for (var i = 0; i < keys.length; i++) i]
        .every((i) => keys[i] == i);
    return isList
        ? entries.values.toList()
        : {for (final MapEntry(:key, :value) in entries.entries) '$key': value};
  }

  static String _property(String key) {
    if (key.isNotEmpty && key.codeUnitAt(0) == 0) {
      final end = key.indexOf('\u0000', 1);
      return end < 0 ? key : key.substring(end + 1);
    }
    return key;
  }
}
