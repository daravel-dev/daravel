import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
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

/// The text the editor's fix of `string_validation_rule` writes for [dsl]
/// written as a plain literal in a `validate` map: the same chain as
/// [ruleChainSource], so the cases above hold for the fix too.
String? fixedText(String dsl) {
  final escaped = dsl
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');
  final source =
      "import 'package:daravel/daravel.dart';\n"
      "Future<void> f(Request r) => r.validate({'f': '$escaped'});\n";
  final unit = parseString(content: source).unit;
  const rule = StringValidationRule();
  String? text;
  rule.check(unit, (node, _) {
    final fix = rule.fixFor(unit, node);
    if (fix != null && fix.edits.length == 1) {
      text = fix.edits.single.replacement;
    }
  });
  return text;
}
