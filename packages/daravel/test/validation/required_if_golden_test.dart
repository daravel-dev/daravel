import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `required_if` and `required_unless` against Laravel itself: each case
/// of `fixtures/laravel_required_if.json` was run through
/// `Validator::make` in Laravel 13.40.0 / PHP 8.3 (the interop image,
/// without network), and Daravel must report the same attributes with the
/// same messages.
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_required_if.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(30)));
  });

  for (final c in cases) {
    // PHP writes an empty array for `{}`.
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
    test('$rules with $data', () async {
      final errors = await Validator(data, rules).run();
      expect(errors, expected);
    });
  }
}
