import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/email_rfc.dart';
import 'package:test/test.dart';

/// The egulias/EmailValidator 4 port against Laravel itself: each address
/// of `fixtures/laravel_email_rfc.json` was validated by Laravel 13.40 with
/// `email`, `email:rfc` and `email:strict` (see the fixture's `source`).
void main() {
  ruleGolden();
  upgradeNoteRows();

  final fixture = jsonDecode(
    File('test/validation/fixtures/laravel_email_rfc.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = [
    for (final c
        in (fixture['cases']! as List<Object?>).cast<Map<String, Object?>>())
      // Laravel input arrives as text: an address that is not valid UTF-8
      // cannot reach the rule, so it is not compared.
      if (_decode(c['address']! as String) case final email?)
        (
          email: email,
          rfc: c['email:rfc']! as bool,
          strict: c['email:strict']! as bool,
          plain: c['email']! as bool,
        ),
  ];

  test('the fixture is Laravel\'s', () {
    expect(fixture['laravel'], startsWith('13.'));
    expect(fixture['egulias'], startsWith('4.'));
    expect(cases.length, greaterThan(150));
    expect(cases.where((c) => c.rfc), isNotEmpty);
    expect(cases.where((c) => !c.rfc), isNotEmpty);
  });

  // Laravel refuses \r and \n before egulias sees the address; that check
  // belongs to the rule, so the parser is compared without them.
  final parsed = [
    for (final c in cases)
      if (!c.email.contains('\r') && !c.email.contains('\n')) c,
  ];

  test('plain email agrees with Laravel on every address', () {
    final wrong = [
      for (final c in parsed)
        if (rfcEmailValid(c.email) != c.plain)
          '${jsonEncode(c.email)}: Laravel email ${c.plain}',
    ];
    expect(wrong, isEmpty, reason: '${wrong.length} of ${parsed.length}');
  });

  test('rfc agrees with Laravel on every address', () {
    final wrong = [
      for (final c in parsed)
        if (rfcEmailValid(c.email) != c.rfc)
          '${jsonEncode(c.email)}: Laravel ${c.rfc}',
    ];
    expect(wrong, isEmpty, reason: '${wrong.length} of ${parsed.length}');
  });

  test('the client pattern never refuses an address Laravel accepts', () {
    final pattern = const EmailRule().pattern;
    final refused = [
      for (final c in parsed)
        if (c.rfc && !pattern.hasMatch(c.email)) jsonEncode(c.email),
    ];
    expect(refused, isEmpty);
  });

  test('strict agrees with Laravel on every address', () {
    final wrong = [
      for (final c in parsed)
        if (strictEmailValid(c.email) != c.strict)
          '${jsonEncode(c.email)}: Laravel ${c.strict} '
              '(${parseRfcEmail(c.email).warnings})',
    ];
    expect(wrong, isEmpty, reason: '${wrong.length} of ${parsed.length}');
  });
}

String? _decode(String base64Value) {
  try {
    return utf8.decode(base64.decode(base64Value));
  } on FormatException {
    return null;
  }
}

/// The same addresses through the rule, where Laravel's own check (a
/// string without \r or \n) runs before egulias: every address of the
/// fixture, those with line breaks included.
void ruleGolden() {
  test('the email:rfc and email:strict rules agree with Laravel', () async {
    final fixture = jsonDecode(
      File('test/validation/fixtures/laravel_email_rfc.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
    final wrong = <String>[];
    var compared = 0;
    for (final c
        in (fixture['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
      final email = _decode(c['address']! as String);
      if (email == null || email.isEmpty) {
        // Not valid UTF-8 (cannot arrive as text), or empty (a rule that is
        // not implicit skips it).
        continue;
      }
      compared++;
      for (final rule in ['email', 'email:rfc', 'email:strict']) {
        final passes = (await Validator(
          {'e': email},
          {'e': rule},
        ).run()).isEmpty;
        if (passes != c[rule]) {
          wrong.add('$rule ${jsonEncode(email)}: Laravel ${c[rule]}');
        }
      }
    }
    expect(compared, greaterThan(150));
    expect(wrong, isEmpty, reason: '${wrong.length} of ${compared * 3}');
  });
}

/// The rows of the upgrade note (changelog.d/e2-w9-email-rfc.md).
void upgradeNoteRows() {
  test('the upgrade note table holds', () async {
    Future<bool> passes(String email, String rule) async =>
        (await Validator({'e': email}, {'e': rule}).run()).isEmpty;
    for (final email in [
      'user@localhost',
      '"first last"@example.com',
      'user@[127.0.0.1]',
      'user(comment)@example.com',
    ]) {
      expect(await passes(email, 'email'), isTrue, reason: email);
      expect(await passes(email, 'email:strict'), isFalse, reason: email);
    }
    for (final email in ['a..b@example.com', 'not-an-email']) {
      expect(await passes(email, 'email'), isFalse, reason: email);
    }
    expect(await passes('user@localhost', 'email:filter'), isFalse);
  });
}
