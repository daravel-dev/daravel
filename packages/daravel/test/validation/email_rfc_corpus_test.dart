import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/email_rfc.dart';
import 'package:test/test.dart';

/// The second golden for the egulias port: the is_email test set that
/// egulias/EmailValidator ships (years of collected edge cases: control
/// characters, comments, folding white space, address literals) and
/// addresses of 300 and 1 000 characters, each run through Laravel 13.40's
/// Validator (`fixtures/laravel_email_rfc_corpus.json`, see its `source`).
/// Laravel accepts a 1 000-character local part with `email:rfc` (egulias
/// only warns) and refuses it with `email:strict`: no length cap before the
/// parser, here either.
void main() {
  final fixture = jsonDecode(
    File('test/validation/fixtures/laravel_email_rfc_corpus.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = [
    for (final c
        in (fixture['cases']! as List<Object?>).cast<Map<String, Object?>>())
      if (_decode(c['address']! as String) case final email?)
        (
          email: email,
          from: c['from']! as String,
          plain: c['email']! as bool,
          rfc: c['email:rfc']! as bool,
          strict: c['email:strict']! as bool,
        ),
  ];

  test('the corpus is Laravel 13\'s, with the long addresses', () {
    expect(fixture['laravel'], startsWith('13.'));
    expect(cases.length, greaterThan(160));
    expect(cases.where((c) => c.from.startsWith('is_email')), isNotEmpty);
    expect(cases.where((c) => c.email.length > 1000), isNotEmpty);
    expect(cases.where((c) => c.rfc), isNotEmpty);
    expect(cases.where((c) => !c.rfc), isNotEmpty);
  });

  test('the lexer splits every corpus address as doctrine\'s regex', () {
    final reference = RegExp(
      emailRfcScanPattern,
      caseSensitive: false,
      unicode: true,
    );
    for (final c in cases) {
      final expected = [
        for (final m in reference.allMatches(c.email))
          for (var g = 1; g <= 7; g++)
            if (m.group(g) case final s? when s.isNotEmpty) s,
      ];
      // Every position starts a capturing match: the matches cover the
      // address, so the captured groups are the whole split.
      expect(expected.join(), c.email, reason: c.from);
      expect(emailRfcTokens(c.email), expected, reason: c.from);
    }
  });

  // Laravel refuses \r and \n before egulias sees the address, and skips an
  // empty value (the rule is not implicit): the parser is compared without
  // them, the rule with every address.
  final parsed = [
    for (final c in cases)
      if (c.email.isNotEmpty &&
          !c.email.contains('\r') &&
          !c.email.contains('\n'))
        c,
  ];
  for (final (mode, read, check) in [
    ('rfc', (_C c) => c.rfc, rfcEmailValid),
    ('strict', (_C c) => c.strict, strictEmailValid),
  ]) {
    test('$mode agrees with Laravel on every corpus address', () {
      final wrong = [
        for (final c in parsed)
          if (check(c.email) != read(c))
            '${c.from} ${jsonEncode(c.email)}: Laravel ${read(c)}',
      ];
      expect(wrong, isEmpty, reason: '${wrong.length} of ${parsed.length}');
    });
  }

  test('the email rules agree with Laravel on every corpus address', () async {
    final wrong = <String>[];
    for (final c in cases) {
      // Empty: a rule that is not implicit skips it.
      if (c.email.isEmpty) {
        continue;
      }
      for (final (rule, expected) in [
        ('email', c.plain),
        ('email:rfc', c.rfc),
        ('email:strict', c.strict),
      ]) {
        final passes = (await Validator(
          {'e': c.email},
          {'e': rule},
        ).run()).isEmpty;
        if (passes != expected) {
          wrong.add(
            '$rule ${c.from} ${jsonEncode(c.email)}: Laravel $expected',
          );
        }
      }
    }
    expect(wrong, isEmpty, reason: '${wrong.length} differ');
  });
}

typedef _C = ({String email, String from, bool plain, bool rfc, bool strict});

String? _decode(String base64Value) {
  try {
    return utf8.decode(base64.decode(base64Value));
  } on FormatException {
    return null;
  }
}
