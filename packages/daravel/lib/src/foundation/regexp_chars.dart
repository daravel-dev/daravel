/// Character classes of Dart's `RegExp` (non-Unicode mode), for code that
/// replaces a regular expression with a loop and must match what it did.
library;

/// Whether [codeUnit] is white space to `RegExp`'s `\s`: tab, line feed,
/// vertical tab, form feed, carriage return, space, U+00A0, U+1680, U+2000
/// to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
bool isRegExpSpace(int codeUnit) =>
    codeUnit == 0x20 ||
    (codeUnit >= 0x09 && codeUnit <= 0x0D) ||
    codeUnit == 0xA0 ||
    codeUnit == 0x1680 ||
    (codeUnit >= 0x2000 && codeUnit <= 0x200A) ||
    codeUnit == 0x2028 ||
    codeUnit == 0x2029 ||
    codeUnit == 0x202F ||
    codeUnit == 0x205F ||
    codeUnit == 0x3000 ||
    codeUnit == 0xFEFF;

/// Whether [codeUnit] is a line terminator, which `RegExp`'s `.` does not
/// match without `dotAll`: line feed, carriage return, U+2028 and U+2029.
bool isLineTerminator(int codeUnit) =>
    codeUnit == 0x0A ||
    codeUnit == 0x0D ||
    codeUnit == 0x2028 ||
    codeUnit == 0x2029;

/// Whether [codeUnit] is a word character to `RegExp`'s `\w` and `\b`:
/// `[A-Za-z0-9_]`.
bool isRegExpWord(int codeUnit) =>
    (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    codeUnit == 0x5F;
