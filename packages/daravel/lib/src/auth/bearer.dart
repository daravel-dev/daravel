import '../foundation/regexp_chars.dart';

/// The token of an `Authorization` header value: what
/// `RegExp(r'^\s*Bearer\s+(.+?)\s*$', caseSensitive: false)` captured, or
/// null where it did not match, in one pass and the same on every input.
///
/// That regular expression took time quadratic in a run of white space
/// inside the token (`Bearer a` + 65 536 spaces + `b`: 30 s), and the token
/// and JWT guards ran it on every request before looking the token up.
///
/// Its terms, as Dart's `RegExp` reads them:
/// - `\s` is the white space of [isRegExpSpace];
/// - `Bearer` without case sensitivity is ASCII only (a non-ASCII
///   character never folds to an ASCII letter);
/// - `.` is any code unit but a line terminator ([isLineTerminator]);
/// - `^` and `$` are the start and end of the value.
///
/// So: white space, `Bearer`, at least one white space, then the token,
/// with the white space at its end left out. A token holding a line
/// terminator is no token. When only white space follows `Bearer`, the
/// expression took the last of it that is not a line terminator (and not
/// the first one after the word) as the token, so this does as well.
String? bearerTokenFromHeader(String header) {
  final length = header.length;
  var at = 0;
  while (at < length && isRegExpSpace(header.codeUnitAt(at))) {
    at++;
  }
  const word = 'bearer';
  if (length - at < word.length) {
    return null;
  }
  for (var i = 0; i < word.length; i++) {
    // Only bit 0x20 tells an ASCII capital from its small letter.
    if ((header.codeUnitAt(at + i) | 0x20) != word.codeUnitAt(i)) {
      return null;
    }
  }
  final afterWord = at + word.length;
  if (afterWord == length || !isRegExpSpace(header.codeUnitAt(afterWord))) {
    return null;
  }
  var start = afterWord;
  while (start < length && isRegExpSpace(header.codeUnitAt(start))) {
    start++;
  }
  var end = length;
  while (end > start && isRegExpSpace(header.codeUnitAt(end - 1))) {
    end--;
  }
  if (end > start) {
    for (var i = start; i < end; i++) {
      if (isLineTerminator(header.codeUnitAt(i))) {
        return null;
      }
    }
    return header.substring(start, end);
  }
  for (var i = length - 1; i > afterWord; i--) {
    if (!isLineTerminator(header.codeUnitAt(i))) {
      return header.substring(i, i + 1);
    }
  }
  return null;
}
