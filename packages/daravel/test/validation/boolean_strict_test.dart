import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

Future<Map<String, List<String>>> _errors(
  Map<String, Object?> data,
  Object rule,
) => Validator(data, {'f': rule}).run();

Future<bool> _passes(Object? value, Object rule) async =>
    (await _errors({'f': value}, rule)).isEmpty;

const _message = 'The f field must be true or false.';

/// `boolean:strict` follows Laravel 12.x `validateBoolean`
/// (`in_array($value, [true, false], true)`); plain `boolean` is unchanged
/// (ADR-030: it keeps accepting `'true'`, `'false'`, `1.0` and `0.0`).
///
/// An empty string is skipped by every non-implicit rule (as Laravel's
/// `presentOrRuleIsImplicit`), so it passes both forms here.
void main() {
  // Value, plain `boolean` today, `boolean:strict` (PHP in_array, strict).
  final table = <(String, Object?, bool, bool)>[
    ('true', true, true, true),
    ('false', false, true, true),
    ('1', 1, true, false),
    ('0', 0, true, false),
    ("'1'", '1', true, false),
    ("'0'", '0', true, false),
    ("'true'", 'true', true, false),
    ("'false'", 'false', true, false),
    ('1.0', 1.0, true, false),
    ('0.0', 0.0, true, false),
    ("'yes'", 'yes', false, false),
    ('a list', [1], false, false),
    ('a map', {'a': 1}, false, false),
    // Skipped, not judged, by a non-implicit rule.
    ("''", '', true, true),
  ];

  group('every value against the string form', () {
    for (final (label, value, plain, strict) in table) {
      test('boolean with $label', () async {
        expect(await _passes(value, 'boolean'), plain);
      });
      test('boolean:strict with $label', () async {
        expect(await _passes(value, 'boolean:strict'), strict);
      });
      test('bool:strict with $label', () async {
        expect(await _passes(value, 'bool:strict'), strict);
      });
      test('Rules.boolean(strict: true) with $label', () async {
        expect(await _passes(value, [Rules.boolean(strict: true)]), strict);
      });
      test('Rules.boolean() with $label', () async {
        expect(await _passes(value, [Rules.boolean()]), plain);
      });
    }
  });

  group('the parameter', () {
    Future<bool> rejects1(String rule) async => !await _passes(1, rule);

    test('only the first parameter, exactly strict, counts', () async {
      expect(await rejects1('boolean:strict'), isTrue);
      expect(await rejects1('boolean:strict,x'), isTrue);
      expect(await rejects1('bool:strict'), isTrue);
      expect(await rejects1('boolean:x,strict'), isFalse);
      expect(await rejects1('boolean:STRICT'), isFalse);
      expect(await rejects1('boolean:Strict'), isFalse);
      expect(await rejects1('boolean:'), isFalse);
      expect(await rejects1('boolean'), isFalse);
    });

    test('the parameter is compared after the parser trims spaces', () async {
      // As for every rule: the rule segment and each parameter are trimmed.
      expect(await rejects1('boolean: strict'), isTrue);
      expect(await rejects1('boolean:strict '), isTrue);
      expect(await rejects1('boolean: strict ,x'), isTrue);
      expect(await rejects1('boolean:s trict'), isFalse);
    });

    test('a lenient form still accepts what plain boolean accepts', () async {
      for (final rule in ['boolean:x,strict', 'boolean:STRICT', 'boolean:']) {
        for (final value in <Object?>[true, false, 1, 0, '1', '0', 'true']) {
          expect(await _passes(value, rule), isTrue, reason: '$rule $value');
        }
      }
    });

    test('the parsed rule carries the flag', () {
      expect(
        (RuleParser.parseOne('boolean:strict') as BooleanRule).strict,
        true,
      );
      expect(
        (RuleParser.parseOne('bool:strict,x') as BooleanRule).strict,
        true,
      );
      expect(
        (RuleParser.parseOne('boolean:x,strict') as BooleanRule).strict,
        false,
      );
      expect((RuleParser.parseOne('boolean') as BooleanRule).strict, false);
      expect(const BooleanRule().strict, false);
      expect(Rules.boolean(), isA<BooleanRule>());
      expect((Rules.boolean(strict: true) as BooleanRule).strict, true);
      expect(RuleParser.parseOne('boolean:strict').name, 'boolean');
    });

    test('the chain steps take it too', () async {
      expect(
        await _passes(1, Rules.required().boolean(strict: true).toList()),
        isFalse,
      );
      expect(await _passes(1, Rules.required().boolean().toList()), isTrue);
      expect(
        await _passes(true, Rules.required().boolean(strict: true).toList()),
        isTrue,
      );
      expect(await _passes(1, Rules.boolean().required().toList()), isTrue);
    });
  });

  group('the message and the key', () {
    test('boolean:strict answers as boolean does', () async {
      for (final value in <Object?>[1, '1', 'true', 'yes']) {
        expect(await _errors({'f': value}, 'boolean:strict'), {
          'f': [_message],
        }, reason: '$value');
      }
      expect(await _errors({'f': 'yes'}, 'boolean'), {
        'f': [_message],
      });
      expect(
        await Validator({'f': 1}, {'f': 'boolean:strict'}, locale: 'id').run(),
        {
          'f': ['Kolom f harus bernilai true atau false.'],
        },
      );
    });

    test('a custom message under the boolean key applies to both', () async {
      for (final rule in ['boolean', 'boolean:strict']) {
        expect(
          await Validator(
            {'f': 'yes'},
            {'f': rule},
            messages: {'f.boolean': 'nope'},
          ).run(),
          {
            'f': ['nope'],
          },
        );
      }
    });
  });

  group('null and a missing field', () {
    test('null fails without nullable, as plain boolean does', () async {
      expect(await _passes(null, 'boolean'), isFalse);
      expect(await _passes(null, 'boolean:strict'), isFalse);
    });

    test('nullable lets null through', () async {
      expect(await _passes(null, 'nullable|boolean'), isTrue);
      expect(await _passes(null, 'nullable|boolean:strict'), isTrue);
      expect(await _passes(1, 'nullable|boolean:strict'), isFalse);
      expect(await _passes(true, 'nullable|boolean:strict'), isTrue);
    });

    test('a missing field is not validated', () async {
      expect(await _errors({}, 'boolean:strict'), isEmpty);
      expect(await _errors({}, 'nullable|boolean:strict'), isEmpty);
      expect(await _errors({}, 'boolean'), isEmpty);
    });

    test('required|boolean:strict on a missing field fails as required', () {
      expect(_errors({}, 'required|boolean:strict'), completion(contains('f')));
    });
  });

  group('a JSON-decoded body', () {
    test('true and false pass, a number does not', () async {
      for (final (body, strict, plain) in [
        ('{"f": true}', true, true),
        ('{"f": false}', true, true),
        ('{"f": 1}', false, true),
        ('{"f": 0}', false, true),
        ('{"f": 1.0}', false, true),
        ('{"f": "1"}', false, true),
        ('{"f": "true"}', false, true),
        ('{"f": null}', false, false),
      ]) {
        final data = jsonDecode(body) as Map<String, Object?>;
        expect(
          (await _errors(data, 'boolean:strict')).isEmpty,
          strict,
          reason: body,
        );
        expect((await _errors(data, 'boolean')).isEmpty, plain, reason: body);
      }
    });
  });

  group('the read-back is unchanged', () {
    test('asBool still reads everything it read before', () {
      expect(BooleanRule.asBool('true'), isTrue);
      expect(BooleanRule.asBool(0), isFalse);
      expect(BooleanRule.asBool('yes'), isNull);
    });
  });

  group('a dependent rule reading a boolean field', () {
    // Laravel's `shouldConvertToBoolean` is
    // `in_array('boolean', $this->rules[$parameter] ?? [])`: a loose
    // comparison with the whole rule string, so a field written
    // `boolean:strict` is NOT a boolean field for `required_if:f,true` and
    // its siblings, and the `'true'` parameter stays a string there.
    //
    // The neighbour `g` is `<rule>:f,true`; `g` is missing for the first
    // four rules and holds 'x' for `prohibited_if` and `missing_if`. Each
    // cell is whether `g` FAILS, in the order of [_dependents].
    const dependents = [
      'required_if',
      'required_unless',
      'accepted_if',
      'prohibited_if',
      'missing_if',
      'present_if',
    ];

    // `f` written `boolean:strict`: the answers of a PHP run of Laravel
    // 12.x's own logic (parseDependentRuleParameters and the six validators).
    const strictRows = <(String, Object?, List<bool>)>[
      ('1', 1, [false, true, false, false, false, false]),
      ('0', 0, [false, true, false, false, false, false]),
      ("'1'", '1', [false, true, false, false, false, false]),
      ("'0'", '0', [false, true, false, false, false, false]),
      ("'false'", 'false', [false, true, false, false, false, false]),
      ('true', true, [true, false, true, true, true, true]),
      ('false', false, [false, true, false, false, false, false]),
    ];

    // `f` written plain `boolean`: what Daravel answered before
    // `boolean:strict` was honoured (generated by running the unmodified
    // code once), pinned so this change cannot move it. Note that `'false'`
    // differs from Laravel for the sibling rules (a known difference of
    // plain `boolean`, not decided by this change).
    const plainRows = <(String, Object?, List<bool>)>[
      ('1', 1, [true, false, true, true, true, true]),
      ('0', 0, [false, true, false, false, false, false]),
      ("'1'", '1', [true, false, true, true, true, true]),
      ("'0'", '0', [false, true, false, false, false, false]),
      ("'false'", 'false', [true, false, false, false, false, false]),
      ('true', true, [true, false, true, true, true, true]),
      ('false', false, [false, true, false, false, false, false]),
    ];

    Future<List<bool>> row(Object? value, String fieldRule) async {
      final cells = <bool>[];
      for (final dependent in dependents) {
        final data = <String, Object?>{
          'f': value,
          if (dependent == 'prohibited_if' || dependent == 'missing_if')
            'g': 'x',
        };
        final errors = await Validator(data, {
          'f': fieldRule,
          'g': '$dependent:f,true',
        }).run();
        cells.add(errors.containsKey('g'));
      }
      return cells;
    }

    for (final (label, value, expected) in strictRows) {
      test('boolean:strict field with $label', () async {
        expect(await row(value, 'boolean:strict'), expected);
      });
    }
    for (final (label, value, expected) in plainRows) {
      test('plain boolean field with $label', () async {
        expect(await row(value, 'boolean'), expected);
      });
    }
  });
}
