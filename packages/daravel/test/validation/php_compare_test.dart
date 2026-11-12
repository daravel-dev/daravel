import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
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

  // The rules that cast a float to text, as Laravel 13 decided each case
  // (daravel-interop-laravel-13): doesnt_start_with and doesnt_end_with,
  // and the key `unique` skips (prepareUniqueId's FILTER_VALIDATE_INT,
  // then stripslashes; 1e14 is not an int there, so it stays '1.0E+14').
  test('the rules casting a float to text write it so', () async {
    final data = {'a': 0.1 + 0.2, 'b': 1e14, 'c': -0.0};
    for (final (field, rule, passes) in [
      ('a', 'doesnt_start_with:0.3', false),
      ('a', 'doesnt_end_with:0.3', false),
      ('a', 'doesnt_start_with:0.30000000000000004', true),
      ('b', 'doesnt_start_with:1.0E', false),
      ('b', 'doesnt_end_with:+14', false),
      ('b', 'doesnt_start_with:1000', true),
      ('c', 'doesnt_start_with:-0', false),
    ]) {
      final errors = await Validator(data, {field: rule}).run();
      expect(errors.isEmpty, passes, reason: '$field $rule');
    }
    expect(UniqueRule.skippedKey(0.1 + 0.2), '0.3');
    expect(UniqueRule.skippedKey(1e14), '1.0E+14');
    expect(UniqueRule.skippedKey(-0.0), '0');
    expect(UniqueRule.skippedKey(1.0), '1');
  });
}
