import 'dart:typed_data';

import 'case_folding.g.dart';

// The distance of each BMP code point to its folding (0: it folds to itself).
final Int32List _bmpDelta = () {
  final delta = Int32List(0x10000);
  for (final from in unicodeCaseFolding.keys.where((k) => k < 0x10000)) {
    delta[from] = unicodeCaseFolding[from]! - from;
  }
  return delta;
}();

/// Simple Unicode 15.0.0 case folding (status C and S), as PCRE2 `/iu`;
/// `null` for text with an unpaired UTF-16 surrogate. No folding crosses
/// the BMP boundary, so the result has the length of [value] in UTF-16
/// units and is written in place into one buffer.
String? tryCaseFold(String value) {
  final delta = _bmpDelta;
  final out = Uint16List.fromList(value.codeUnits);
  var changed = false;
  for (var i = 0; i < out.length; i++) {
    final unit = out[i];
    if (unit < 0xD800 || unit > 0xDFFF) {
      final d = delta[unit];
      if (d != 0) {
        out[i] = unit + d;
        changed = true;
      }
      continue;
    }
    final low = unit < 0xDC00 && i + 1 < out.length ? out[++i] : 0;
    if (low < 0xDC00 || low > 0xDFFF) {
      return null;
    }
    final folded =
        unicodeCaseFolding[0x10000 + ((unit - 0xD800) << 10) + low - 0xDC00];
    if (folded != null) {
      out[i - 1] = 0xD800 + ((folded - 0x10000) >> 10);
      out[i] = 0xDC00 + ((folded - 0x10000) & 0x3FF);
      changed = true;
    }
  }
  return changed ? String.fromCharCodes(out) : value;
}
