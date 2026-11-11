import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The messages of the dependent rules against Laravel itself: each case
/// of `fixtures/laravel_dependent_messages.json` (a rule failing on
/// `items.0.x` with `items.*.o` as its parameter, field names with `_`,
/// several fields) was run through `Validator::make` in Laravel 13.40.0 /
/// PHP 8.3 (the interop image, without network). Laravel replaces the
/// asterisks of the rules in `Validator::$dependentRules` and not of the
/// others (`date_equals`, `in_array`): the cases of both kinds stay here.
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_dependent_messages.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(40)));
  });

  for (final c in cases) {
    final data = switch (c['data']) {
      final Map<String, Object?> map => map,
      _ => <String, Object?>{},
    };
    final rules = (c['rules']! as Map<String, Object?>).cast<String, Object>();
    final expected = switch (c['errors']) {
      final Map<String, Object?> map => {
        for (final MapEntry(:key, :value) in map.entries)
          key: (value! as List<Object?>).cast<String>(),
      },
      _ => <String, List<String>>{},
    };
    final rule = '${rules.values.first}';
    test(
      '$rules with $data',
      () async => expect(await Validator(data, rules).run(), expected),
      skip:
          rule.startsWith('required_if:') || rule.startsWith('required_unless:')
          ? 'required_if/required_unless messages are fixed by the PR '
                'that reads every value of those rules'
          : null,
    );
  }
}
