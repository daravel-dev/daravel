import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `distinct` (with `strict` and `ignore_case`) and `in_array` against
/// Laravel 13 itself: every case of
/// `fixtures/laravel_distinct_in_array.json` (hand-picked and seeded random
/// inputs) was run through Laravel's Validator, and Daravel must report the
/// same errors, messages included.
///
/// One departure, on purpose: where a list or map is among the values of
/// `distinct:ignore_case`, Laravel throws (PHP's array-to-string warning,
/// a 500); Daravel never takes a list for a string, and validates.
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_distinct_in_array.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(1100)));
  });

  for (final (i, c) in cases.indexed) {
    final data = (c['data']! as Map<String, Object?>);
    final rules = (c['rules']! as Map<String, Object?>).cast<String, Object>();
    test('#$i $rules with ${jsonEncode(data)}', () async {
      final errors = await Validator(data, rules).run();
      if (c.containsKey('throws')) {
        // Laravel failed the request; Daravel validates it.
        expect(rules.values.single, contains('ignore_case'));
        return;
      }
      final expected = {
        for (final MapEntry(:key, :value)
            in (c['errors']! as Map<String, Object?>).entries)
          key: (value! as List<Object?>).cast<String>(),
      };
      expect(errors, expected);
    });
  }
}
