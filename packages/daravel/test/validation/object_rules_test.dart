import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Rule::when`, `Rule::unless`, `Rule::forEach` and `Rule::anyOf` (W9.4a),
/// with the semantics of Laravel 13's `ConditionalRules`, `NestedRules`
/// and `AnyOf`.
void main() {
  Future<Map<String, List<String>>> errorsOf(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).run();

  group('when / unless', () {
    test('a bool picks the rules or the otherwise rules', () async {
      Map<String, Object> rules(bool admin) => <String, Object>{
        'role': [
          Rules.when(
            admin,
            [
              Rules.required(),
              Rules.inList(['admin']),
            ],
            otherwise: [Rules.prohibited()],
          ),
        ],
      };
      expect(await errorsOf({}, rules(true)), contains('role'));
      expect(await errorsOf({'role': 'admin'}, rules(true)), isEmpty);
      expect(await errorsOf({}, rules(false)), isEmpty);
      expect((await errorsOf({'role': 'x'}, rules(false)))['role'], [
        'The role field is prohibited.',
      ]);
    });

    test('unless is when with the lists swapped', () async {
      final rules = {
        'vat': Rules.unless(false, [Rules.required()]),
        'tax': Rules.unless(true, [Rules.required()]),
      };
      expect((await errorsOf({}, rules)).keys, ['vat']);
    });

    test('a condition on the input, as a whole value or in a list', () async {
      final rules = <String, Object>{
        'company': Rules.whenInput((input) => input['type'] == 'business', [
          Rules.required(),
          Rules.string(),
        ]),
        'vat': [
          Rules.string(),
          Rules.unlessInput((input) => input['type'] == 'business', [
            Rules.prohibited(),
          ]),
        ],
      };
      expect((await errorsOf({'type': 'business'}, rules)).keys, ['company']);
      expect(await errorsOf({'type': 'person', 'vat': 'X1'}, rules), {
        'vat': ['The vat field is prohibited.'],
      });
    });

    test('decided once, on the input before excluded keys go', () async {
      var calls = 0;
      final rules = <String, Object>{
        'kind': [
          Rules.excludeIf('kind', ['skip']),
        ],
        'items.*': Rules.whenInput((input) {
          calls++;
          // Laravel's filterConditionalRules sees the data as given.
          return input.containsKey('kind');
        }, [Rules.integer()]),
      };
      final errors = await errorsOf({
        'kind': 'skip',
        'items': ['a', 'b'],
      }, rules);
      expect(calls, 1);
      expect(errors.keys, ['items.0', 'items.1']);
    });

    test('a when inside a when is resolved too', () async {
      final rules = {
        'a': Rules.when(true, [
          Rules.when(true, [Rules.required()]),
        ]),
      };
      expect((await errorsOf({}, rules)).keys, ['a']);
    });
  });

  group('forEach', () {
    test('builds the rules of each element from its value', () async {
      final seen = <ForEachItem>[];
      final rules = {
        'items.*.qty': Rules.forEach((item) {
          seen.add(item);
          return item.value == 0
              ? [Rules.integer(), Rules.min(1)]
              : [Rules.integer()];
        }),
      };
      final errors = await errorsOf({
        'items': [
          {'qty': 0},
          {'qty': 'x'},
          {'qty': 3},
        ],
      }, rules);
      expect(errors.keys, ['items.0.qty', 'items.1.qty']);
      expect(errors['items.0.qty'], [
        'The items.0.qty field must be at least 1.',
      ]);
      expect(seen.map((i) => i.attribute), [
        'items.0.qty',
        'items.1.qty',
        'items.2.qty',
      ]);
      expect(seen.first.parent, {'qty': 0});
      expect(seen.first.input, contains('items'));
    });

    test(
      'keyed rules validate keys of the element and are validated data',
      () async {
        final validator = Validator(
          {
            'items': [
              {'type': 'book', 'isbn': '978'},
              {'type': 'pen'},
            ],
          },
          {
            'items.*': Rules.forEachNested(
              (item) => {
                'type': [Rules.required(), Rules.string()],
                if ((item.value as Map<String, Object?>)['type'] == 'book')
                  'isbn': [Rules.required(), Rules.string()],
              },
            ),
          },
        );
        expect(await validator.passes(), isTrue);
        expect(validator.validated().toMap(), {
          'items': [
            {'type': 'book', 'isbn': '978'},
            {'type': 'pen'},
          ],
        });
        final missing = Validator(
          {
            'items': [
              {'type': 'book'},
            ],
          },
          {
            'items.*': Rules.forEachNested(
              (item) => {
                'isbn': [Rules.required()],
              },
            ),
          },
        );
        expect(await missing.run(), {
          'items.0.isbn': ['The items.0.isbn field is required.'],
        });
      },
    );

    test('a callback that returns forEach forever stops at the limit', () {
      late Rule self;
      self = Rules.forEach((item) => [self]);
      expect(
        errorsOf(
          {
            'a': [1],
          },
          {'a.*': self},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('[a.*]'), contains('${Validator.maxRuleNesting}')),
          ),
        ),
      );
    });
  });

  group('anyOf', () {
    final idOrEmail = {
      'login': Rules.anyOf([
        [Rules.email()],
        [Rules.integer(), Rules.min(1)],
      ]),
    };

    test('passes when one alternative passes', () async {
      expect(await errorsOf({'login': 'ana@example.com'}, idOrEmail), isEmpty);
      expect(await errorsOf({'login': '42'}, idOrEmail), isEmpty);
      expect(await errorsOf({'login': 'nope'}, idOrEmail), {
        'login': ['The login field is invalid.'],
      });
    });

    test('is not implicit: an absent value is skipped', () async {
      expect(await errorsOf({}, idOrEmail), isEmpty);
    });

    test('an alternative sees the value alone, as Laravel', () async {
      // required_if names another field, which the alternative's own
      // validator does not hold: the rule sees it as missing.
      final rules = {
        'code': Rules.anyOf([
          [Rules.requiredIf('mode', 'strict'), Rules.size(3)],
        ]),
      };
      expect(await errorsOf({'mode': 'strict', 'code': 'ab'}, rules), {
        'code': ['The code field is invalid.'],
      });
      expect(await errorsOf({'mode': 'strict', 'code': 'abc'}, rules), isEmpty);
    });

    test('keyed alternatives validate the keys of a map value', () async {
      final rules = {
        'target': Rules.anyOfKeyed([
          {
            'type': [
              Rules.inList(['user']),
            ],
            'id': [Rules.required(), Rules.integer()],
          },
          {
            'type': [
              Rules.inList(['team']),
            ],
            'slug': [Rules.required(), Rules.string()],
          },
        ]),
      };
      expect(
        await errorsOf({
          'target': {'type': 'team', 'slug': 'core'},
        }, rules),
        isEmpty,
      );
      expect(
        (await errorsOf({
          'target': {'type': 'team', 'id': 4},
        }, rules)).keys,
        ['target'],
      );
      // Not a map: wrapped as Laravel's [$value], so a keyed rule misses.
      expect((await errorsOf({'target': 'user'}, rules)).keys, ['target']);
    });

    test('the message follows the locale', () async {
      final errors = await Validator(
        {'login': 'nope'},
        idOrEmail,
        locale: 'id',
      ).run();
      expect(errors['login'], ['Kolom login tidak valid.']);
    });
  });

  test('an expanding rule run on its own says what it is', () {
    final rule = Rules.when(true, [Rules.required()]);
    expect(
      () => rule.passes(
        ValidationContext(
          attribute: 'a',
          pattern: 'a',
          value: null,
          present: false,
          data: const {},
        ),
      ),
      throwsStateError,
    );
  });

  test('a chain step adds the conditional', () async {
    final rules = {
      'a': Rules.string().when(true, [Rules.max(2)]),
    };
    expect((await errorsOf({'a': 'abc'}, rules)).keys, ['a']);
  });
}
