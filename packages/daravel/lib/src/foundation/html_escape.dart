/// [value] with `& < > " '` escaped, for HTML text and attribute values:
/// Laravel's `e()` (`htmlspecialchars` with `ENT_QUOTES`), so `'` becomes
/// `&#039;`.
///
/// One declaration, exported by both `package:daravel/daravel.dart` and
/// `package:daravel/html.dart`, so a file importing both can call it.
String escapeHtml(String value) {
  // Most values need no escaping: return them as they are.
  var clean = true;
  for (var i = 0; i < value.length; i++) {
    switch (value.codeUnitAt(i)) {
      case 0x26 || 0x3C || 0x3E || 0x22 || 0x27:
        clean = false;
    }
    if (!clean) {
      break;
    }
  }
  if (clean) {
    return value;
  }
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    switch (unit) {
      case 0x26:
        out.write('&amp;');
      case 0x3C:
        out.write('&lt;');
      case 0x3E:
        out.write('&gt;');
      case 0x22:
        out.write('&quot;');
      case 0x27:
        out.write('&#039;');
      default:
        out.writeCharCode(unit);
    }
  }
  return out.toString();
}
