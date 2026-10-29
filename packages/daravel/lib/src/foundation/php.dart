import 'dart:convert';

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
