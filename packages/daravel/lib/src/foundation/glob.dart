/// Whether [text] matches [pattern], where `*` stands for any run of
/// characters (none included) and every other character for itself: Laravel's
/// `Str::is`.
///
/// Linear in the text, unlike the regular expression `Str::is` builds (each
/// `*` becomes `.*`): with several `*`, that one backtracks polynomially, and
/// a long input (an `Origin` header of a few kilobytes) took minutes. Each
/// literal part is found left to right; the leftmost place for a middle part
/// leaves the most room for the parts after it, so no other place can match
/// where it does not.
bool globMatches(String pattern, String text, {bool caseSensitive = true}) {
  if (!caseSensitive) {
    pattern = pattern.toLowerCase();
    text = text.toLowerCase();
  }
  final parts = pattern.split('*');
  if (parts.length == 1) {
    return text == pattern;
  }
  final first = parts.first;
  final last = parts.last;
  if (text.length < first.length + last.length ||
      !text.startsWith(first) ||
      !text.endsWith(last)) {
    return false;
  }
  var at = first.length;
  final end = text.length - last.length;
  for (var i = 1; i < parts.length - 1; i++) {
    final part = parts[i];
    if (part.isEmpty) {
      continue;
    }
    final found = text.indexOf(part, at);
    if (found == -1 || found + part.length > end) {
      return false;
    }
    at = found + part.length;
  }
  return true;
}
