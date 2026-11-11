import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The presence rules of laravel/framework 13.x `ValidatesAttributes` that
/// Daravel lacked before Blueprint #151 (W9.4a): `missing*`, `present_*`,
/// `prohibited_if_accepted`/`_declined`, `required_if_declined`,
/// `required_array_keys`. Messages are Laravel 13's `lang/en/validation.php`
/// with its `ReplacesAttributes` placeholders.
void main() {
  Future<Map<String, List<String>>> errors(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).run();

  Future<bool> ok(Map<String, Object?> data, String rule) async =>
      (await errors(data, {'a': rule})).isEmpty;

  group('missing', () {
    test(
      'passes only when the key is absent, even null or empty fails',
      () async {
        expect(await ok({}, 'missing'), isTrue);
        expect(await ok({'a': null}, 'missing'), isFalse);
        expect(await ok({'a': ''}, 'missing'), isFalse);
        expect(await errors({'a': 1}, {'a': 'missing'}), {
          'a': ['The a field must be missing.'],
        });
      },
    );

    test('missing_if and missing_unless compare the other field', () async {
      expect(await ok({'a': 1, 'b': 'x'}, 'missing_if:b,x'), isFalse);
      expect(await ok({'a': 1, 'b': 'y'}, 'missing_if:b,x'), isTrue);
      expect(await ok({'b': 'x'}, 'missing_if:b,x'), isTrue);
      expect(await ok({'a': 1, 'b': 'x'}, 'missing_unless:b,x'), isTrue);
      expect(await ok({'a': 1, 'b': 'y'}, 'missing_unless:b,x'), isFalse);
      expect(await errors({'a': 1, 'b': 'x'}, {'a': 'missing_if:b,x'}), {
        'a': ['The a field must be missing when b is x.'],
      });
      // `replaceMissingUnless`: :value is the rule's value, not the input.
      expect(await errors({'a': 1, 'b': 'y'}, {'a': 'missing_unless:b,x'}), {
        'a': ['The a field must be missing unless b is x.'],
      });
    });

    test('missing_if compares a boolean field as a boolean', () async {
      expect(
        await errors(
          {'a': 1, 'b': '1'},
          {'a': 'missing_if:b,true', 'b': 'boolean'},
        ),
        contains('a'),
      );
    });

    test(
      'missing_with and missing_with_all look at keys, not values',
      () async {
        expect(await ok({'a': 1, 'b': null}, 'missing_with:b,c'), isFalse);
        expect(await ok({'a': 1}, 'missing_with:b,c'), isTrue);
        expect(await ok({'a': 1, 'b': 1}, 'missing_with_all:b,c'), isTrue);
        expect(
          await ok({'a': 1, 'b': 1, 'c': 1}, 'missing_with_all:b,c'),
          isFalse,
        );
        expect(await errors({'a': 1, 'b': 1}, {'a': 'missing_with:b,c'}), {
          'a': ['The a field must be missing when b / c is present.'],
        });
        expect(
          await errors({'a': 1, 'b': 1, 'c': 1}, {'a': 'missing_with_all:b,c'}),
          {
            'a': ['The a field must be missing when b / c are present.'],
          },
        );
      },
    );

    test('nested keys', () async {
      expect(
        await ok({
          'a': 1,
          'user': {'name': null},
        }, 'missing_with:user.name'),
        isFalse,
      );
    });
  });

  group('present_unless, present_with, present_with_all', () {
    test('present_unless', () async {
      expect(await ok({'b': 'y'}, 'present_unless:b,x'), isFalse);
      expect(await ok({'b': 'x'}, 'present_unless:b,x'), isTrue);
      expect(await ok({'a': null, 'b': 'y'}, 'present_unless:b,x'), isTrue);
      expect(await errors({'b': 'y'}, {'a': 'present_unless:b,x'}), {
        'a': ['The a field must be present unless b is x.'],
      });
    });

    test('present_with and present_with_all', () async {
      expect(await ok({'b': 1}, 'present_with:b,c'), isFalse);
      expect(await ok({'a': '', 'b': 1}, 'present_with:b,c'), isTrue);
      expect(await ok({}, 'present_with:b,c'), isTrue);
      expect(await ok({'b': 1}, 'present_with_all:b,c'), isTrue);
      expect(await ok({'b': 1, 'c': 1}, 'present_with_all:b,c'), isFalse);
      expect(await errors({'b': 1}, {'a': 'present_with:b,c'}), {
        'a': ['The a field must be present when b / c is present.'],
      });
      expect(await errors({'b': 1, 'c': 1}, {'a': 'present_with_all:b,c'}), {
        'a': ['The a field must be present when b / c are present.'],
      });
    });
  });

  group('acceptance conditions', () {
    test('prohibited_if_accepted', () async {
      expect(
        await ok({'a': 'x', 'b': 'yes'}, 'prohibited_if_accepted:b'),
        isFalse,
      );
      expect(
        await ok({'a': '', 'b': 'yes'}, 'prohibited_if_accepted:b'),
        isTrue,
      );
      expect(
        await ok({'a': 'x', 'b': 'no'}, 'prohibited_if_accepted:b'),
        isTrue,
      );
      expect(await ok({'a': 'x'}, 'prohibited_if_accepted:b'), isTrue);
      expect(
        await errors({'a': 'x', 'b': true}, {'a': 'prohibited_if_accepted:b'}),
        {
          'a': ['The a field is prohibited when b is accepted.'],
        },
      );
    });

    test('prohibited_if_declined', () async {
      expect(
        await ok({'a': 'x', 'b': 'off'}, 'prohibited_if_declined:b'),
        isFalse,
      );
      expect(
        await ok({'a': 'x', 'b': 'on'}, 'prohibited_if_declined:b'),
        isTrue,
      );
      expect(
        await errors({'a': 'x', 'b': 0}, {'a': 'prohibited_if_declined:b'}),
        {
          'a': ['The a field is prohibited when b is declined.'],
        },
      );
    });

    test('required_if_declined is implicit', () async {
      expect(await ok({'b': 'false'}, 'required_if_declined:b'), isFalse);
      expect(
        await ok({'a': '', 'b': 'false'}, 'required_if_declined:b'),
        isFalse,
      );
      expect(
        await ok({'a': 'x', 'b': 'false'}, 'required_if_declined:b'),
        isTrue,
      );
      expect(await ok({'b': 'true'}, 'required_if_declined:b'), isTrue);
      expect(await errors({'b': 'no'}, {'a': 'required_if_declined:b'}), {
        'a': ['The a field is required when b is declined.'],
      });
    });
  });

  group('required_array_keys', () {
    test('an object or list with every key', () async {
      expect(
        await ok({
          'a': {'x': 1, 'y': null},
        }, 'required_array_keys:x,y'),
        isTrue,
      );
      expect(
        await ok({
          'a': {'x': 1},
        }, 'required_array_keys:x,y'),
        isFalse,
      );
      expect(
        await ok({
          'a': ['p', 'q'],
        }, 'required_array_keys:0,1'),
        isTrue,
      );
      expect(await ok({'a': 'x'}, 'required_array_keys:x'), isFalse);
      expect(
        await errors(
          {
            'a': {'x': 1},
          },
          {'a': 'required_array_keys:x,y'},
        ),
        {
          'a': ['The a field must contain entries for: x, y.'],
        },
      );
    });
  });

  test('every builder parses back from its string', () {
    final pairs = <String, Rule>{
      'missing': Rules.missing(),
      'missing_if:b,x': Rules.missingIf('b', ['x']),
      'missing_unless:b,x': Rules.missingUnless('b', ['x']),
      'missing_with:b': Rules.missingWith(['b']),
      'missing_with_all:b': Rules.missingWithAll(['b']),
      'present_unless:b,x': Rules.presentUnless('b', ['x']),
      'present_with:b': Rules.presentWith(['b']),
      'present_with_all:b': Rules.presentWithAll(['b']),
      'prohibited_if_accepted:b': Rules.prohibitedIfAccepted('b'),
      'prohibited_if_declined:b': Rules.prohibitedIfDeclined('b'),
      'required_if_declined:b': Rules.requiredIfDeclined('b'),
      'required_array_keys:x': Rules.requiredArrayKeys(['x']),
    };
    for (final MapEntry(key: dsl, value: rule) in pairs.entries) {
      final parsed = RuleParser.parseOne(dsl);
      expect(parsed.name, rule.name, reason: dsl);
      expect(parsed.runtimeType, rule.runtimeType, reason: dsl);
    }
  });
}
