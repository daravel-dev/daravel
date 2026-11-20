import 'dart:typed_data';

import 'case_folding.g.dart';

/// Internal test counter for [tryCaseFold] calls (assert-only).
int debugDistinctFoldCalls = 0;

/// Internal test counter for strict identity encodings (assert-only).
int debugDistinctIdentityCalls = 0;

/// Resets internal distinct work counters.
void debugResetDistinctCounters() {
  debugDistinctFoldCalls = 0;
  debugDistinctIdentityCalls = 0;
}

/// Single-pass UTF-8 check and Unicode 15.0.0 C+S simple case folding;
/// returns `null` on an unpaired UTF-16 surrogate.
String? tryCaseFold(String value) {
  assert(() {
    debugDistinctFoldCalls++;
    return true;
  }());
  final length = value.length;
  var hasUpper = false;
  var ascii = true;
  for (var i = 0; i < length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0x80) {
      ascii = false;
      break;
    }
    if (unit >= 0x41 && unit <= 0x5A) {
      hasUpper = true;
    }
  }
  if (ascii) {
    if (!hasUpper) {
      return value;
    }
    final units = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final unit = value.codeUnitAt(i);
      units[i] = (unit >= 0x41 && unit <= 0x5A) ? unit | 0x20 : unit;
    }
    return String.fromCharCodes(units);
  }
  final out = <int>[];
  for (var i = 0; i < length; i++) {
    final unit = value.codeUnitAt(i);
    final int rune;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= length) {
        return null;
      }
      final low = value.codeUnitAt(i + 1);
      if (low < 0xDC00 || low > 0xDFFF) {
        return null;
      }
      i++;
      rune = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return null;
    } else {
      rune = unit;
    }
    out.add(unicodeCaseFolding[rune] ?? rune);
  }
  return String.fromCharCodes(out);
}

/// Simple Unicode 15.0.0 case folding (status C and S), returning [value]
/// unchanged if it contains an unpaired surrogate.
String caseFold(String value) => tryCaseFold(value) ?? value;
