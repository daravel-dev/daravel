import 'dart:convert';
import 'dart:io';

import 'package:daravel/src/validation/php_compare.dart';
import 'package:test/test.dart';

void main() {
  // `distinct:ignore_case` compares the values as PHP writes them, and
  // PHP's (string) of a float keeps 14 significant digits (`precision`):
  // `0.1 + 0.2` is '0.3', `-0.0` is '-0', `1e14` is '1.0E+14', and an
  // exact tie rounds half to even.
  test('phpNumberString writes a float as PHP 8 does', () {
    final golden = jsonDecode(
      File('test/validation/fixtures/php_float_string.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final cases = (golden['cases']! as List<Object?>).cast<List<Object?>>();
    expect(cases, hasLength(greaterThan(300)));
    for (final [value as num, text as String] in cases) {
      expect(phpNumberString(value.toDouble()), text, reason: '$value');
    }
    expect(phpNumberString(-0.0), '-0');
    expect(phpNumberString(double.infinity), 'INF');
    expect(phpNumberString(double.nan), 'NAN');
    expect(phpNumberString(12345678901234567), '12345678901234567');
  });
}
