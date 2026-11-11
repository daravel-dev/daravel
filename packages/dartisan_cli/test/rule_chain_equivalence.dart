import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Rules that need a database (`unique`, `exists`): compared by their
/// description only, not run.
const Set<String> _needsDatabase = {'unique', 'exists'};

/// Inputs each pair of rule lists validates the same way: the field `f`
/// with values of every kind, beside the other fields dependent rules
/// read.
final List<Map<String, Object?>> _inputs = [
  for (final value in <Object?>[
    null,
    '',
    'abc',
    'ABC',
    'a@b.co',
    'https://daravel.dev',
    '0',
    '7',
    '300',
    '2.5',
    5,
    -1,
    true,
    'yes',
    '2025-06-01',
    ['x', 'y'],
    {'id': 1, 'name': 'n'},
    "it's",
  ]) ...[
    {'f': value},
    {
      'f': value,
      'role': 'admin',
      'terms': 'yes',
      'a': 'x',
      'b': 'y',
      'other': 3,
      'password': 'p',
      'old': 'q',
      'start': '2020-01-01',
      'end': '2040-01-01',
      'f_confirmation': value,
      'repeat': value,
      'tags': ['abc', 'x'],
    },
  ],
];

/// [dsl] and [chain] hold the same rules (type, name, parameters, schema
/// hints) and, unless one needs a database, validate every input alike.
Future<void> expectSameRules(String dsl, List<Rule> chain) async {
  final parsed = RuleParser.parse(dsl);
  expect(chain, hasLength(parsed.length));
  for (var i = 0; i < parsed.length; i++) {
    final (a, b) = (parsed[i], chain[i]);
    expect(b.runtimeType, a.runtimeType, reason: 'rule $i');
    expect(b.name, a.name, reason: 'rule $i');
    expect(b.implicit, a.implicit, reason: '${a.name} implicit');
    expect(
      '${b.parameters}',
      '${a.parameters}',
      reason: '${a.name} parameters',
    );
    expect('${b.schemaHint}', '${a.schemaHint}', reason: '${a.name} schema');
  }
  if (parsed.any((r) => _needsDatabase.contains(r.name))) {
    return;
  }
  for (final input in _inputs) {
    final fromString = await Validator(input, {'f': parsed}).run();
    final fromChain = await Validator(input, {'f': chain}).run();
    expect(fromChain, fromString, reason: '$input');
  }
}
