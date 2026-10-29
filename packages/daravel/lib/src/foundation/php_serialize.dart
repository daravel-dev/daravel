import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

/// A PHP object read by [phpUnserialize] (`O:8:"stdClass":1:{...}`): its
/// class name and properties, kept so the value can be written back
/// unchanged by [phpSerialize]. Daravel code does not create these.
final class PhpObject {
  const PhpObject(this.className, this.properties);

  final String className;

  /// Property names as PHP wrote them: `name` for public, `\0*\0name` for
  /// protected and `\0Class\0name` for private.
  final Map<String, Object?> properties;

  @override
  bool operator ==(Object other) =>
      other is PhpObject &&
      other.className == className &&
      const DeepCollectionEquality().equals(other.properties, properties);

  @override
  int get hashCode => Object.hash(className, properties.length);

  @override
  String toString() => 'PhpObject($className, $properties)';
}

/// PHP `serialize()` of [value]: `null`, `bool`, `int`, `double`, `String`,
/// `List` (an array with keys 0..n-1), `Map` (an array; a key that is a
/// canonical decimal integer becomes an integer key, as PHP does) and
/// [PhpObject]. Strings count UTF-8 bytes. Anything else throws
/// [ArgumentError].
String phpSerialize(Object? value) {
  final out = StringBuffer();
  _write(out, value);
  return out.toString();
}

void _write(StringBuffer out, Object? value) {
  switch (value) {
    case null:
      out.write('N;');
    case bool():
      out.write(value ? 'b:1;' : 'b:0;');
    case int():
      out.write('i:$value;');
    case double():
      out
        ..write('d:')
        ..write(_double(value))
        ..write(';');
    case String():
      _writeString(out, value);
    case List():
      out.write('a:${value.length}:{');
      for (var i = 0; i < value.length; i++) {
        out.write('i:$i;');
        _write(out, value[i]);
      }
      out.write('}');
    case Map():
      out.write('a:${value.length}:{');
      for (final entry in value.entries) {
        _writeKey(out, entry.key);
        _write(out, entry.value);
      }
      out.write('}');
    case PhpObject(:final className, :final properties):
      out.write('O:${utf8.encode(className).length}:"$className":');
      out.write('${properties.length}:{');
      for (final entry in properties.entries) {
        _writeString(out, entry.key);
        _write(out, entry.value);
      }
      out.write('}');
    default:
      throw ArgumentError.value(
        value,
        'value',
        'cannot be PHP-serialized (${value.runtimeType}); convert it to a '
            'map, list, string, number, bool or null first',
      );
  }
}

void _writeKey(StringBuffer out, Object? key) {
  switch (key) {
    case int():
      out.write('i:$key;');
    case String() when _canonicalInt.hasMatch(key):
      out.write('i:$key;');
    case String():
      _writeString(out, key);
    case bool():
      out.write('i:${key ? 1 : 0};');
    case null:
      out.write('s:0:"";');
    default:
      throw ArgumentError.value(key, 'key', 'PHP array keys are int or string');
  }
}

/// `"0"`, `"42"`, `"-7"`: what PHP turns into an integer key (not `"007"`
/// or `"1.0"`).
final RegExp _canonicalInt = RegExp(r'^(0|-?[1-9]\d{0,18})$');

void _writeString(StringBuffer out, String value) {
  out
    ..write('s:')
    ..write(utf8.encode(value).length)
    ..write(':"')
    ..write(value)
    ..write('";');
}

/// `serialize_precision = -1`: the shortest text that reads back as the
/// same double, integral values without a fraction (`d:1;`).
String _double(double value) {
  if (value.isNaN) {
    return 'NAN';
  }
  if (value.isInfinite) {
    return value.isNegative ? '-INF' : 'INF';
  }
  if (value == value.truncateToDouble() && value.abs() < 1e15) {
    final text = value.truncate().toString();
    return value.isNegative && value == 0 ? '-0' : text;
  }
  var text = value.toString();
  if (text.contains('e')) {
    // Dart: 1e+21 / 1.5e-7; PHP: 1.0E+21 / 1.5E-7.
    text = text.replaceFirst('e', 'E');
    if (!text.contains('.') && !text.contains('E-')) {
      text = text.replaceFirst('E', '.0E');
    }
  }
  return text;
}

/// PHP `unserialize()` of [data]: arrays whose keys are exactly 0..n-1 in
/// order become a `List`, other arrays a `Map<String, Object?>` (integer
/// keys as decimal strings), objects a [PhpObject]. References (`r:`,
/// `R:`) and `Serializable` payloads (`C:`) throw [FormatException], as
/// does any malformed input.
Object? phpUnserialize(String data) {
  final reader = _Reader(utf8.encode(data));
  final value = reader.read();
  if (reader.offset != reader.bytes.length) {
    throw FormatException(
      'Trailing data after the serialized value',
      data,
      reader.offset,
    );
  }
  return value;
}

/// Whether [data] starts like a `serialize()` payload, so a reader can
/// tell it from JSON without parsing.
bool looksPhpSerialized(String data) =>
    data.length >= 2 &&
    switch (data[0]) {
      'N' => data == 'N;',
      'b' ||
      'i' ||
      'd' ||
      's' ||
      'a' ||
      'O' ||
      'C' ||
      'r' ||
      'R' => data[1] == ':',
      _ => false,
    };

final class _Reader {
  _Reader(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  int offset = 0;

  Object? read() {
    final type = _next();
    switch (type) {
      case 0x4E: // N;
        _expect(0x3B);
        return null;
      case 0x62: // b:1;
        _expect(0x3A);
        final value = _digits();
        _expect(0x3B);
        return value != '0';
      case 0x69: // i:42;
        _expect(0x3A);
        final value = _digits();
        _expect(0x3B);
        return int.parse(value);
      case 0x64: // d:1.5;
        _expect(0x3A);
        final start = offset;
        while (offset < bytes.length && bytes[offset] != 0x3B) {
          offset++;
        }
        final text = ascii.decode(bytes.sublist(start, offset));
        _expect(0x3B);
        return switch (text) {
          'NAN' => double.nan,
          'INF' => double.infinity,
          '-INF' => double.negativeInfinity,
          _ => double.parse(text),
        };
      case 0x73: // s:5:"hello";
        _expect(0x3A);
        final value = _string();
        _expect(0x3B);
        return value;
      case 0x61: // a:2:{...}
        _expect(0x3A);
        final count = int.parse(_digits());
        _expect(0x3A);
        _expect(0x7B);
        final entries = <(Object, Object?)>[];
        for (var i = 0; i < count; i++) {
          final key = read();
          if (key is! int && key is! String) {
            throw FormatException(
              'Array key is not int or string',
              null,
              offset,
            );
          }
          entries.add((key!, read()));
        }
        _expect(0x7D);
        return _array(entries);
      case 0x4F: // O:8:"stdClass":1:{s:1:"a";i:1;}
        _expect(0x3A);
        final className = _string();
        _expect(0x3A);
        final count = int.parse(_digits());
        _expect(0x3A);
        _expect(0x7B);
        final properties = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = read();
          if (key is! String) {
            throw FormatException(
              'Property name is not a string',
              null,
              offset,
            );
          }
          properties[key] = read();
        }
        _expect(0x7D);
        return PhpObject(className, properties);
      case 0x43 || 0x72 || 0x52:
        throw FormatException(
          'Unsupported serialized value "${String.fromCharCode(type)}:" '
          '(Serializable payload or reference)',
          null,
          offset - 1,
        );
      default:
        throw FormatException('Not a PHP serialized value', null, offset - 1);
    }
  }

  Object? _array(List<(Object, Object?)> entries) {
    var sequential = true;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].$1 != i) {
        sequential = false;
        break;
      }
    }
    if (sequential) {
      return [for (final (_, value) in entries) value];
    }
    return <String, Object?>{for (final (key, value) in entries) '$key': value};
  }

  int _next() {
    if (offset >= bytes.length) {
      throw FormatException('Unexpected end of serialized data', null, offset);
    }
    return bytes[offset++];
  }

  void _expect(int unit) {
    final actual = _next();
    if (actual != unit) {
      throw FormatException(
        'Expected "${String.fromCharCode(unit)}", found '
        '"${String.fromCharCode(actual)}"',
        null,
        offset - 1,
      );
    }
  }

  String _digits() {
    final start = offset;
    if (offset < bytes.length &&
        (bytes[offset] == 0x2D || bytes[offset] == 0x2B)) {
      offset++;
    }
    while (offset < bytes.length &&
        bytes[offset] >= 0x30 &&
        bytes[offset] <= 0x39) {
      offset++;
    }
    if (offset == start) {
      throw FormatException('Expected a number', null, offset);
    }
    return ascii.decode(bytes.sublist(start, offset));
  }

  /// `<len>:"<bytes>"`: the length counts bytes, so the content may hold
  /// any UTF-8 (or a `"`).
  String _string() {
    final length = int.parse(_digits());
    _expect(0x3A);
    _expect(0x22);
    if (offset + length > bytes.length) {
      throw FormatException('String runs past the end', null, offset);
    }
    final value = utf8.decode(bytes.sublist(offset, offset + length));
    offset += length;
    _expect(0x22);
    return value;
  }
}
