import 'dart:convert';
import 'dart:typed_data';

import 'php_serialize.dart';

/// PHP's `rawurlencode`: every byte of the UTF-8 encoding except
/// `A-Z a-z 0-9 - _ . ~` becomes `%XX` (upper case).
String phpRawUrlEncode(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E;
    if (unreserved) {
      out.writeCharCode(byte);
    } else {
      out
        ..write('%')
        ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// Rewrites [json] (the output of `dart:convert`'s encoder) into the bytes
/// PHP's `json_encode()` writes with default flags: `/` becomes `\/` and
/// every non-ASCII UTF-16 unit `\uxxxx` (lower-case hex, surrogate pairs
/// as two escapes). Control characters and quotes are already escaped the
/// same way by both.
///
/// [escapeSlashes] `false` is `JSON_UNESCAPED_SLASHES` (Laravel's error
/// bodies): `/` stays as is, non-ASCII is still escaped.
///
/// With [emptyMapsAsArrays], an empty object `{}` becomes `[]`, as an
/// empty PHP array encodes; Dart maps stand for PHP arrays in a port.
///
/// One pass that copies unchanged runs as substrings, so the cost stays
/// close to the native encoder's (a per-character rewrite of a large
/// response costs several times more).
String phpJsonFromDart(
  String json, {
  bool emptyMapsAsArrays = false,
  bool escapeSlashes = true,
}) {
  StringBuffer? out;
  var start = 0;
  var inString = false;
  final length = json.length;
  for (var i = 0; i < length; i++) {
    final unit = json.codeUnitAt(i);
    if (inString) {
      if (unit == 0x5C) {
        // An escape: skip the escaped character (`\"`, `\\`, `\u`...).
        i++;
      } else if (unit == 0x22) {
        inString = false;
      } else if ((unit == 0x2F && escapeSlashes) || unit > 0x7F) {
        (out ??= StringBuffer())
          ..write(json.substring(start, i))
          ..write(
            unit == 0x2F
                ? r'\/'
                : '\\u${unit.toRadixString(16).padLeft(4, '0')}',
          );
        start = i + 1;
      }
    } else if (unit == 0x22) {
      inString = true;
    } else if (emptyMapsAsArrays &&
        unit == 0x7B &&
        i + 1 < length &&
        json.codeUnitAt(i + 1) == 0x7D) {
      (out ??= StringBuffer())
        ..write(json.substring(start, i))
        ..write('[]');
      i++;
      start = i + 1;
    }
  }
  if (out == null) {
    return json;
  }
  out.write(json.substring(start));
  return out.toString();
}

/// Writes the bytes of PHP's `json_encode()` for a Dart value in one pass:
/// the same output as `jsonEncode` followed by [phpJsonFromDart], without
/// the intermediate string and its rewrite (on a 1 MB response the rewrite
/// cost more than the encoding itself).
///
/// Values: `null`, `bool`, `num` (finite), `String`, `List`, `Map` with
/// string keys and [PhpObject]; anything else goes through [toEncodable]
/// once, as `dart:convert` does, or throws [JsonUnsupportedObjectError].
/// A cycle throws [JsonCyclicError].
///
/// With [emptyMapsAsArrays] (the default), an empty map is `[]`, as an
/// empty PHP array encodes: Dart maps stand for PHP arrays in a port. A
/// [PhpObject] is always an object, so `PhpObject('stdClass', {})` is `{}`
/// like PHP's `(object) []`. [escapeSlashes] `false` is
/// `JSON_UNESCAPED_SLASHES`.
final class PhpJsonEncoder {
  const PhpJsonEncoder({
    this.toEncodable,
    this.emptyMapsAsArrays = true,
    this.escapeSlashes = true,
  });

  /// Converts a value the encoder does not know into one it does (a
  /// `DateTime` into a string, a model into a map). Applied once per value.
  final Object? Function(Object? nonEncodable)? toEncodable;

  final bool emptyMapsAsArrays;
  final bool escapeSlashes;

  String convert(Object? value) {
    final out = StringBuffer();
    _PhpJsonWriter(out, this).writeObject(value);
    return out.toString();
  }
}

final class _PhpJsonWriter {
  _PhpJsonWriter(this._out, this._encoder);

  final StringBuffer _out;
  final PhpJsonEncoder _encoder;

  /// Containers being written, for cycle detection (identity, as
  /// `dart:convert`).
  final List<Object> _seen = <Object>[];

  void writeObject(Object? object) {
    if (_writeValue(object)) {
      return;
    }
    _checkCycle(object!);
    final Object? custom;
    try {
      final convert = _encoder.toEncodable;
      if (convert == null) {
        throw JsonUnsupportedObjectError(object);
      }
      custom = convert(object);
    } on JsonUnsupportedObjectError {
      _seen.removeLast();
      rethrow;
    } on Object catch (error) {
      _seen.removeLast();
      throw JsonUnsupportedObjectError(object, cause: error);
    }
    if (!_writeValue(custom)) {
      _seen.removeLast();
      throw JsonUnsupportedObjectError(object);
    }
    _seen.removeLast();
  }

  void _checkCycle(Object object) {
    for (final seen in _seen) {
      if (identical(seen, object)) {
        throw JsonCyclicError(object);
      }
    }
    _seen.add(object);
  }

  /// Writes [object] when it is a JSON value; `false` otherwise.
  bool _writeValue(Object? object) {
    switch (object) {
      case null:
        _out.write('null');
      case true:
        _out.write('true');
      case false:
        _out.write('false');
      case final num number:
        if (!number.isFinite) {
          return false;
        }
        _out.write(number.toString());
      case final String text:
        _writeString(text);
      case final PhpObject php:
        _checkCycle(php);
        _writeProperties(php.properties);
        _seen.removeLast();
      case final List<Object?> list:
        _checkCycle(list);
        _writeList(list);
        _seen.removeLast();
      case final Map<Object?, Object?> map:
        _checkCycle(map);
        final ok = _writeMap(map);
        _seen.removeLast();
        return ok;
      default:
        return false;
    }
    return true;
  }

  void _writeList(List<Object?> list) {
    _out.write('[');
    for (var i = 0; i < list.length; i++) {
      if (i > 0) {
        _out.write(',');
      }
      writeObject(list[i]);
    }
    _out.write(']');
  }

  bool _writeMap(Map<Object?, Object?> map) {
    if (map.isEmpty) {
      _out.write(_encoder.emptyMapsAsArrays ? '[]' : '{}');
      return true;
    }
    _writeProperties(map);
    return true;
  }

  /// `forEach`, not `entries`: no `MapEntry` per field (a wide result set
  /// has tens of thousands). A key that is not a string fails the whole
  /// encoding, as in `dart:convert`.
  void _writeProperties(Map<Object?, Object?> map) {
    _out.write('{');
    var first = true;
    map.forEach((Object? key, Object? value) {
      if (key is! String) {
        throw JsonUnsupportedObjectError(
          map,
          cause: 'Map keys must be strings, found ${key.runtimeType}.',
        );
      }
      if (!first) {
        _out.write(',');
      }
      first = false;
      _writeString(key);
      _out.write(':');
      writeObject(value);
    });
    _out.write('}');
  }

  /// `dart:convert`'s escapes (`\"`, `\\`, `\b \t \n \f \r`, `\u00xx` for
  /// other control characters) plus PHP's: `\/` and `\uxxxx` for every
  /// UTF-16 unit above 0x7F, lone surrogates included.
  void _writeString(String text) {
    final plain = _encoder.escapeSlashes ? _plainWithSlash : _plain;
    final length = text.length;
    _out.write('"');
    var start = 0;
    for (var i = 0; i < length; i++) {
      final unit = text.codeUnitAt(i);
      // One table lookup for the common case, an unescaped ASCII unit.
      if (unit < 0x80 && plain[unit] != 0) {
        continue;
      }
      _flush(text, start, i);
      start = i + 1;
      if (unit > 0x7F) {
        // Digit by digit: no `toRadixString`/`padLeft` strings per unit
        // (a response in a non-Latin script escapes most of its text).
        _out
          ..write(r'\u')
          ..writeCharCode(_hex.codeUnitAt((unit >> 12) & 0xF))
          ..writeCharCode(_hex.codeUnitAt((unit >> 8) & 0xF))
          ..writeCharCode(_hex.codeUnitAt((unit >> 4) & 0xF))
          ..writeCharCode(_hex.codeUnitAt(unit & 0xF));
      } else if (unit < 0x20) {
        _out.write(switch (unit) {
          0x08 => r'\b',
          0x09 => r'\t',
          0x0A => r'\n',
          0x0C => r'\f',
          0x0D => r'\r',
          _ => '\\u00${unit.toRadixString(16).padLeft(2, '0')}',
        });
      } else {
        _out
          ..write(r'\')
          ..writeCharCode(unit);
      }
    }
    if (start == 0) {
      _out.write(text);
    } else {
      _flush(text, start, length);
    }
    _out.write('"');
  }

  void _flush(String text, int start, int end) {
    if (end > start) {
      _out.write(text.substring(start, end));
    }
  }

  /// ASCII units written as they are: 1 for every unit from 0x20 on except
  /// `"` and `\` (and `/` in [_plainWithSlash]).
  static const String _hex = '0123456789abcdef';

  static final Uint8List _plain = _plainTable(escapeSlash: false);
  static final Uint8List _plainWithSlash = _plainTable(escapeSlash: true);

  static Uint8List _plainTable({required bool escapeSlash}) {
    final table = Uint8List(128);
    for (var unit = 0x20; unit < 0x80; unit++) {
      table[unit] =
          unit == 0x22 || unit == 0x5C || (escapeSlash && unit == 0x2F) ? 0 : 1;
    }
    return table;
  }
}
