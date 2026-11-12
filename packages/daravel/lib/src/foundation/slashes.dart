/// [value] without its leading and trailing `/` (what
/// `replaceAll(RegExp(r'^/+|/+$'), '')` gives), in one pass over the ends.
///
/// The regular expression took time quadratic in a run of slashes that does
/// not end the value (`/x` + 16 000 slashes + `y`: seconds), and request
/// paths reach this.
String trimSlashes(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && value.codeUnitAt(start) == 0x2F) {
    start++;
  }
  while (end > start && value.codeUnitAt(end - 1) == 0x2F) {
    end--;
  }
  return start == 0 && end == value.length
      ? value
      : value.substring(start, end);
}

/// [value] without its trailing `/` (what `replaceAll(RegExp(r'/+$'), '')`
/// gives), in one pass from the end. See [trimSlashes].
String trimTrailingSlashes(String value) {
  var end = value.length;
  while (end > 0 && value.codeUnitAt(end - 1) == 0x2F) {
    end--;
  }
  return end == value.length ? value : value.substring(0, end);
}
