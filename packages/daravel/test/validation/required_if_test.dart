import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `required_if` and `required_unless` as Laravel 13.x decides them
/// (ValidatesAttributes::validateRequiredIf 2189-2204,
/// validateRequiredUnless 2413-2424, parseDependentRuleParameters
/// 2470-2485): several values, `'true'`/`'false'` read as booleans for a
/// boolean input or a field with a `boolean` rule, `'null'` as null for a
/// null input, strict `in_array` for a bool or null input and PHP's loose
/// `==` otherwise, and a missing other field never requiring the field.
void main() {
  Future<bool> requires(
    Map<String, Object?> data,
    String rule, {
    Map<String, Object> extra = const {},
  }) async {
    final errors = await Validator(data, {'x': rule, ...extra}).run();
    return errors.containsKey('x');
  }

  // (input, rule, required?, why). A row marked "old" failed before: the
  // rule read one value and compared the input's text.
  final rows = <(Map<String, Object?>, String, bool, String)>[
    (
      {'role': 'owner'},
      'required_if:role,admin,owner',
      true,
      'old: second value',
    ),
    ({'role': 'admin'}, 'required_if:role,admin,owner', true, 'first value'),
    ({'role': 'guest'}, 'required_if:role,admin,owner', false, 'no value'),
    (<String, Object?>{}, 'required_if:role,admin', false, 'other missing'),
    ({'role': null}, 'required_if:role,null', true, 'null input, null value'),
    (
      {'role': null},
      'required_if:role,NULL',
      true,
      'old: null is case-insensitive',
    ),
    ({'role': null}, 'required_if:role,admin', false, 'null input, strict'),
    ({'role': null}, 'required_if:role,', false, "'' is not null (strict)"),
    ({'flag': true}, 'required_if:flag,true', true, 'bool input'),
    ({'flag': false}, 'required_if:flag,false', true, 'bool input, false'),
    ({'flag': true}, 'required_if:flag,1', false, "strict: '1' is not true"),
    ({'flag': '1'}, 'required_if:flag,true', false, 'no boolean rule: text'),
    ({'qty': 5}, 'required_if:qty,5', true, 'int and numeric text'),
    ({'qty': 5.0}, 'required_if:qty,5', true, 'old: 5.0 == "5"'),
    ({'qty': '05'}, 'required_if:qty,5', true, 'old: numeric strings'),
    ({'qty': ' 5'}, 'required_if:qty,5', true, 'old: leading space numeric'),
    ({'qty': '1e1'}, 'required_if:qty,10', true, 'old: exponent'),
    ({'qty': '0x1A'}, 'required_if:qty,26', false, 'hex is not numeric'),
    ({'qty': 'abc'}, 'required_if:qty,0', false, 'PHP 8: text vs number'),
    ({'qty': 0}, 'required_if:qty,abc', false, 'PHP 8: number vs text'),
    (
      {
        'tags': <Object?>['a'],
      },
      'required_if:tags,a',
      false,
      'array vs text',
    ),
    ({'role': 'bot'}, 'required_unless:role,guest,bot', false, 'old: second'),
    ({'role': 'admin'}, 'required_unless:role,guest,bot', true, 'no value'),
    (<String, Object?>{}, 'required_unless:role,guest', true, 'missing other'),
    ({'role': null}, 'required_unless:role,null', false, 'null matches null'),
    ({'qty': '05'}, 'required_unless:qty,5', false, 'old: numeric'),
  ];

  for (final (data, rule, required, why) in rows) {
    test(
      '$rule with $data: ${required ? 'required' : 'optional'} ($why)',
      () async {
        expect(await requires(data, rule), required);
        // A value present always satisfies it.
        expect(await requires({...data, 'x': 'given'}, rule), isFalse);
      },
    );
  }

  test('a boolean rule on the other field reads true and false as booleans '
      '(old)', () async {
    final boolean = {'flag': 'boolean'};
    expect(
      await requires({'flag': '1'}, 'required_if:flag,true', extra: boolean),
      isTrue,
    );
    expect(
      await requires({'flag': '0'}, 'required_if:flag,false', extra: boolean),
      isTrue,
    );
    expect(
      await requires({'flag': '0'}, 'required_if:flag,true', extra: boolean),
      isFalse,
    );
  });

  test('a * in the other field is the same item', () async {
    final errors = await Validator(
      {
        'items': [
          {'type': 'paid'},
          {'type': 'free'},
        ],
      },
      {'items.*.price': 'required_if:items.*.type,paid,premium'},
    ).run();
    expect(errors.keys, ['items.0.price']);
  });

  test('the messages: :value is the input, :values the rule (old)', () async {
    final ifErrors = await Validator(
      {'role': 'owner'},
      {'x': 'required_if:role,admin,owner'},
    ).run();
    expect(ifErrors['x'], ['The x field is required when role is owner.']);
    final unlessErrors = await Validator(
      {'role': 'admin'},
      {'x': 'required_unless:role,guest,bot'},
    ).run();
    expect(unlessErrors['x'], [
      'The x field is required unless role is in guest, bot.',
    ]);
  });

  test('the typed forms', () async {
    final rules = <String, Object>{
      'a': Rules.requiredIfIn('role', ['admin', 'owner']),
      'b': Rules.requiredUnlessIn('role', ['guest', 'bot']),
      'c': Rules.requiredIf('role', 'owner'),
      'd': Rules.nullable().requiredIfIn('role', ['owner']),
    };
    final errors = await Validator({'role': 'owner'}, rules).run();
    expect(errors.keys.toSet(), {'a', 'b', 'c', 'd'});
    expect(() => Rules.requiredIfIn('role', []), throwsArgumentError);
    expect(() => Validator({}, {'x': 'required_if:role'}), throwsArgumentError);
  });
}
