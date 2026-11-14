/// Values the generators write into Dart and YAML sources (column names,
/// route summaries, `.env` keys, application names), written so that they
/// stay values: a quote, a `$`, a backslash or a line break in them never
/// becomes code.
library;

/// A single-quoted Dart string literal of [value].
String dartString(String value) => "'${dartStringBody(value)}'";

/// [value] escaped for the inside of a single-quoted Dart string: `\`, `'`
/// and `$` escaped, line breaks, tabs and other control characters as
/// escapes.
String dartStringBody(String value) {
  final out = StringBuffer();
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x5C:
        out.write(r'\\');
      case 0x27:
        out.write(r"\'");
      case 0x24:
        out.write(r'\$');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      case < 0x20 || 0x7F:
        out.write('\\x${unit.toRadixString(16).padLeft(2, '0')}');
      default:
        out.writeCharCode(unit);
    }
  }
  return '$out';
}

/// [text] for a `//` or `///` comment: on one line, each line break (and
/// the spaces around it) one space.
String commentText(Object? text) =>
    '$text'.replaceAll(RegExp(r'[ \t]*[\r\n]+[ \t]*'), ' ');

/// A double-quoted YAML scalar of [value], on one line: line breaks as
/// spaces, `\` and `"` escaped, other control characters as escapes.
String yamlString(String value) {
  final out = StringBuffer('"');
  for (final unit in commentText(value).codeUnits) {
    switch (unit) {
      case 0x5C:
        out.write(r'\\');
      case 0x22:
        out.write(r'\"');
      case 0x09:
        out.write(r'\t');
      case < 0x20 || 0x7F:
        out.write('\\x${unit.toRadixString(16).padLeft(2, '0')}');
      default:
        out.writeCharCode(unit);
    }
  }
  out.write('"');
  return '$out';
}

/// Names a generated identifier must not take: Dart's reserved words and
/// built-in identifiers, members every object has, and the members of the
/// classes `names:sync` writes (`query`, `absolute`).
const Set<String> dartReservedNames = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'type',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'query',
  'absolute',
};
