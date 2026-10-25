import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('a chain holds the same rules as the DSL string', () {
    final chain = Rules.required().string().email().max(255);
    expect(chain, isA<RuleBuilder>());
    expect(
      [for (final r in RuleParser.parseValue(chain)) r.name],
      [
        for (final r in RuleParser.parse('required|string|email|max:255'))
          r.name,
      ],
    );
    // Steps keep their parameters.
    final between = RuleParser.parseValue(Rules.nullable().between(1, 5));
    expect(between.last.parameters, {'min': 1, 'max': 5});
  });

  test('chains validate exactly like the DSL, messages included', () async {
    final data = {'email': 'not-an-email', 'age': 12, 'tags': <Object?>[]};
    final fromDsl = Validator(data, const {
      'email': 'required|string|email|max:255',
      'age': 'nullable|integer|min:18',
      'tags': 'required|list',
    });
    final fromChain = Validator(data, {
      'email': Rules.required().string().email().max(255),
      'age': Rules.nullable().integer().min(18),
      'tags': Rules.required().list(),
    });
    expect(await fromDsl.fails(), isTrue);
    expect(await fromChain.fails(), isTrue);
    expect(fromChain.errors, fromDsl.errors);
  });

  test('chains mix with strings and rules in a list', () async {
    final validator = Validator(
      {'code': 'AB-1'},
      {
        'code': [
          'required',
          Rules.string().startsWith(['AB']),
          Rules.custom(
            (c) => '${c.value}'.length > 3 ? null : 'too_short',
            name: 'long_enough',
          ),
        ],
      },
    );
    expect(await validator.passes(), isTrue);
  });

  test('chains describe the same JSON Schema as the DSL', () {
    expect(
      rulesToJsonSchema({'email': Rules.required().string().email().max(255)}),
      rulesToJsonSchema(const {'email': 'required|string|email|max:255'}),
    );
  });
}
