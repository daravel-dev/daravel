import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// `adopt` writes each value so that it reads back as itself, with no
/// reference expanded, whatever it holds: as Daravel reads it, which is as
/// Laravel (phpdotenv 5.8) reads it for these forms (the conformance rows
/// of `LaravelContract.dotenvValues`).
void main() {
  final values = [
    'plain',
    r'secret${A}',
    r"it's ${A}",
    r'${A}',
    r'$A',
    'with space',
    'abc#123',
    '#leading',
    'quote " inside',
    r'back\slash',
    r'back\${A}',
    "mixed ' and \" and \$ and \\",
    'line1\nline2',
    'cr\rlf',
    'tab\there',
    'ff${String.fromCharCode(12)}vt${String.fromCharCode(11)}',
    "multi\nline with ' and \${A}",
    '  padded  ',
    '',
  ];

  for (final value in values) {
    test('${quoteEnvValue(value)} reads back unchanged', () {
      final read = Env.parse('A=one\nV=${quoteEnvValue(value)}\n')['V'];
      expect(read, value);
    });
  }

  test('nothing special: written as it is', () {
    expect(quoteEnvValue('plain'), 'plain');
  });

  test('a value with a quote and a reference: double quotes, \$ escaped', () {
    expect(quoteEnvValue(r"it's ${A}"), r'''"it's \${A}"''');
  });
}
