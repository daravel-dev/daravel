import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/php_email_filter.dart';
import 'package:test/test.dart';

/// `email:filter` and `email:filter_unicode` against PHP itself: every case
/// of `fixtures/php_filter_email.json` was run through
/// `filter_var($email, FILTER_VALIDATE_EMAIL)` and with
/// `FILTER_FLAG_EMAIL_UNICODE` in PHP 8.3.35 / PCRE2 10.42 (the
/// `daravel-interop-laravel-13` image of `bench/interop`,
/// `docker run --rm --network=none ... php`). The cases are hand-picked
/// edges (lengths, quotes, escapes, domain literals, `ſ` and the Kelvin
/// sign, which PCRE folds to `s` and `k` under `/iu`), the shapes that make
/// PHP's regex backtrack, and seeded fuzz. Where PCRE gave up on PHP's
/// regex (`*_pcre_error`, "Backtrack limit exhausted"), PHP answers false,
/// and so must Daravel.
void main() {
  final fixture = jsonDecode(
    File('test/validation/fixtures/php_filter_email.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (fixture['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the fixture is PHP 8.3\'s and covers both outcomes', () {
    expect(fixture['php'], startsWith('8.3.'));
    expect(cases, hasLength(greaterThan(3000)));
    for (final mode in ['filter', 'filter_unicode']) {
      expect(cases.where((c) => c[mode] == true), hasLength(greaterThan(200)));
      expect(cases.where((c) => c[mode] == false), isNotEmpty);
      expect(cases.where((c) => c['${mode}_pcre_error'] != null), isNotEmpty);
    }
  });

  for (final (mode, unicode) in [('filter', false), ('filter_unicode', true)]) {
    test('$mode agrees with PHP on every case', () {
      final disagreements = [
        for (final c in cases)
          if (phpFilterEmail(c['email']! as String, unicode: unicode) !=
              c[mode])
            '${jsonEncode(c['email'])}: PHP says ${c[mode]}',
      ];
      expect(disagreements, isEmpty);
    });

    test(
      'email:$mode is that check, after the line breaks Laravel refuses',
      () async {
        Future<bool> valid(String email) async =>
            (await Validator({'v': email}, {'v': 'email:$mode'}).run()).isEmpty;
        for (final c in cases.take(200)) {
          final email = c['email']! as String;
          // An empty value is skipped by a non-implicit rule, not checked.
          if (email.isEmpty) {
            continue;
          }
          expect(await valid(email), c[mode], reason: jsonEncode(email));
        }
        expect(await valid('a@b.com\n'), isFalse);
      },
    );
  }

  // PHP's regex, run by Dart's engine, took 18 s on the first shape at
  // n = 22 (57 characters) and does not finish at 100; PCRE stops at its
  // backtrack limit. Each check here must take well under a millisecond.
  group('linear time on the inputs that make the regex backtrack', () {
    final q = String.fromCharCode(0x22);
    final bs = String.fromCharCode(0x5C);
    final shapes = <String, String Function(int)>{
      'quote, letter': (n) => '${'${q}a' * n}$q@example.com',
      'letter, quote': (n) => '${'a$q' * n}@example.com',
      'backslash, letter, quote': (n) => '${'${bs}a$q' * n}@example.com',
      'quote, backslash, quote': (n) => '${'$q$bs$q' * n}@example.com',
      'letters, quote pairs': (n) => '$q${'a$q$q' * n}@example.com',
    };
    for (final MapEntry(key: name, value: shape) in shapes.entries) {
      for (final mode in ['filter', 'filter_unicode']) {
        // Through the rule, as a request reaches it.
        test('$name, email:$mode', () async {
          Future<void> check(String email) =>
              Validator({'v': email}, {'v': 'email:$mode'}).run();
          await check('ana@example.com');
          final inputs = [
            shape(100),
            // As long as PHP accepts: 320 octets.
            shape(320).substring(0, 320),
          ];
          for (final input in inputs) {
            final watch = Stopwatch()..start();
            await check(input);
            expect(
              watch.elapsedMilliseconds,
              lessThan(50),
              reason: '${input.length} characters',
            );
          }
        });
      }
    }
  });
}
