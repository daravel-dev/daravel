import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `email:filter` and `email:filter_unicode` against PHP itself: the cases
/// of `fixtures/php_filter_email.json` were run through
/// `filter_var($email, FILTER_VALIDATE_EMAIL)` and with
/// `FILTER_FLAG_EMAIL_UNICODE` in PHP 8.2 (the `daravel-interop-laravel-12`
/// image of `bench/interop`, `docker run --rm --network=none ... php`).
void main() {
  final fixture = jsonDecode(
    File('test/validation/fixtures/php_filter_email.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (fixture['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  Future<bool> valid(String email, String rule) async =>
      (await Validator({'v': email}, {'v': rule}).run()).isEmpty;

  test('the fixture is PHP\'s and covers both outcomes', () {
    expect(fixture['php'], startsWith('8.'));
    expect(cases, hasLength(greaterThan(30)));
    expect(cases.where((c) => c['filter'] == true), isNotEmpty);
    expect(cases.where((c) => c['filter'] == false), isNotEmpty);
  });

  for (final mode in ['filter', 'filter_unicode']) {
    test('email:$mode agrees with PHP on every case', () async {
      final disagreements = <String>[];
      for (final c in cases) {
        final email = c['email']! as String;
        // An empty value is skipped by a non-implicit rule, not checked.
        if (email.isEmpty) {
          continue;
        }
        if (await valid(email, 'email:$mode') != c[mode]) {
          disagreements.add('$email: PHP says ${c[mode]}');
        }
      }
      expect(disagreements, isEmpty);
    });
  }
}
