import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `starts_with`, `ends_with`, `doesnt_start_with` and `doesnt_end_with`
/// against Laravel 13 itself (`fixtures/laravel_affix.json`): a string or
/// a number is cast to text as PHP casts it (`is_string || is_numeric`),
/// anything else fails, and an empty parameter matches nothing
/// (`Str::startsWith`).
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_affix.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(1000)));
  });

  for (final (i, c) in cases.indexed) {
    final data = c['data']! as Map<String, Object?>;
    final rules = (c['rules']! as Map<String, Object?>).cast<String, Object>();
    test('#$i $rules with ${jsonEncode(data)}', () async {
      final expected = {
        for (final MapEntry(:key, :value)
            in (c['errors']! as Map<String, Object?>).entries)
          key: (value! as List<Object?>).cast<String>(),
      };
      expect(await Validator(data, rules).run(), expected);
    });
  }
}
