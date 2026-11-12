/// How deep the arrays and objects of a JSON text nest, read from its bytes
/// in one pass, before it is decoded.
library;

/// The deepest nesting of arrays and objects in the UTF-8 JSON [bytes]:
/// `1` for `[1]` or `{"a":1}`, `2` for `{"a":[1]}`, `0` for a scalar.
///
/// Brackets inside strings do not count, nor does a quote escaped with a
/// backslash end one (`"[\"{"` is a string). The bytes of a multi-byte
/// UTF-8 character are all 0x80 or above, so none is read as a bracket or
/// a quote. The text is not validated: unbalanced brackets count as they
/// open, and the decoder that runs afterwards refuses what is malformed.
///
/// Counting stops once the nesting reaches [stopAt] (when given), and that
/// value is returned: a caller that only compares against a limit reads no
/// further than it must. Time and memory are linear in the length of
/// [bytes], whatever the nesting, with no recursion.
int jsonNesting(List<int> bytes, {int? stopAt}) {
  var depth = 0;
  var deepest = 0;
  var inString = false;
  final length = bytes.length;
  for (var i = 0; i < length; i++) {
    final byte = bytes[i];
    if (inString) {
      if (byte == _backslash) {
        i++; // The escaped character, whatever it is.
      } else if (byte == _quote) {
        inString = false;
      }
      continue;
    }
    switch (byte) {
      case _quote:
        inString = true;
      case _openArray || _openObject:
        depth++;
        if (depth > deepest) {
          deepest = depth;
          if (stopAt != null && deepest >= stopAt) {
            return deepest;
          }
        }
      case _closeArray || _closeObject:
        if (depth > 0) {
          depth--;
        }
    }
  }
  return deepest;
}

const int _quote = 0x22;
const int _backslash = 0x5C;
const int _openArray = 0x5B;
const int _closeArray = 0x5D;
const int _openObject = 0x7B;
const int _closeObject = 0x7D;
