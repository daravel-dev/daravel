import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

enum _Status { draft }

/// Rule completeness in four directions (W9.4c), so a rule that exists only
/// as a string, only as a builder, only in Laravel, or only outside the
/// chain is seen at once:
///
/// 1. every string name `RuleParser` accepts builds a rule of that name;
/// 2. every `Rules.*` builder makes a rule whose name the parser accepts
///    (or one of the named object-only rules);
/// 3. every rule of Laravel 13's `lang/en/validation.php` is known, or
///    named in [_laravelPending] with the slice that adds it;
/// 4. every `Rules.*` builder is also a step of the chain, on `RuleBuilder`
///    and on any rule (`RuleChain`), so `Rules.required().` lists them all.
///
/// Without reflection: the list of builders is read from the source of
/// `rules.dart`, like `architecture_test.dart` reads imports.
void main() {
  final known = InvalidValidationRule.knownRules;

  // The Daravel aliases and the rule each one builds.
  const aliases = <String, String>{
    'int': 'integer',
    'bool': 'boolean',
    'object': 'map',
  };

  // Builders with no string form, in Laravel as here (`Rule::enum`, a
  // closure, `Rule::when`/`unless`/`forEach`/`anyOf`/`can`).
  const objectOnly = <String>{
    'enum',
    'custom',
    'when',
    'unless',
    'for_each',
    'any_of',
    'can',
  };

  test('1. every string name builds a rule of that name', () {
    for (final name in known) {
      final dsl = switch (name) {
        'regex' || 'not_regex' => '$name:/x/',
        'timezone' => name,
        _ => '$name:1,1',
      };
      final rule = RuleParser.parseOne(dsl);
      expect(rule.name, aliases[name] ?? name, reason: dsl);
    }
  });

  test('2. every Rules builder has a string form', () {
    final builders = _sampleBuilders();
    expect(
      builders.keys.toSet(),
      _rulesStatics().difference(_notRuleBuilders),
      reason:
          'a Rules static was added or removed: add it to _sampleBuilders '
          'with a sample call',
    );
    for (final MapEntry(key: method, value: build) in builders.entries) {
      final name = build().name;
      expect(
        known.contains(name) || objectOnly.contains(name),
        isTrue,
        reason:
            'Rules.$method() builds "$name", which RuleParser does not '
            'parse',
      );
    }
  });

  test('3. every Laravel 13 rule is known or pending', () {
    final laravel = {
      for (final key in laravelValidationMessages.keys) key.split('.').first,
    };
    final missing = laravel
        .where((name) => !known.contains(name) && !objectOnly.contains(name))
        .toSet();
    expect(missing, _laravelPending.keys.toSet());
  });

  test('4. every Rules builder is a chain step', () {
    final statics = _rulesStatics().difference(_notRuleBuilders);
    final builder = _methodsOf('RuleBuilder');
    final chain = _methodsOf('RuleChain');
    expect(statics.difference(builder), isEmpty, reason: 'RuleBuilder');
    expect(statics.difference(chain), isEmpty, reason: 'RuleChain');
  });

  test('4. a chain step adds the same rule as its builder', () {
    final chained = Rules.required()
        .missingIf('b', ['x'])
        .requiredArrayKeys(['k'])
        .gt('b')
        .presentWith(['c'])
        .toList();
    expect(chained.map((r) => r.name), [
      'required',
      'missing_if',
      'required_array_keys',
      'gt',
      'present_with',
    ]);
  });
}

/// The public methods of the class or extension [target] of
/// `rule_builder.dart`, from its source.
Set<String> _methodsOf(String target) {
  final unit = parseString(
    content: File('lib/src/validation/rule_builder.dart').readAsStringSync(),
  ).unit;
  final members = [
    for (final declaration in unit.declarations)
      if (declaration case ClassDeclaration(:final namePart, :final body)
          when namePart.typeName.lexeme == target)
        ...body.members
      else if (declaration case ExtensionDeclaration(:final name?, :final body)
          when name.lexeme == target)
        ...body.members,
  ];
  return {
    for (final m in members.whereType<MethodDeclaration>())
      if (!m.name.lexeme.startsWith('_')) m.name.lexeme,
  };
}

/// `Rules` statics that make no single rule: `Rules.of(definition)` gives
/// the typed `unique`/`exists` of a model (W9.4b), whose results are the
/// same `UniqueRule`/`ExistsRule` as `Rules.unique`/`Rules.exists`.
const Set<String> _notRuleBuilders = {'of'};

/// Laravel 13 message keys without a Daravel string rule yet, and why.
/// Shrinks with each W9.4a pull request; empty when the slice is done.
const Map<String, String> _laravelPending = {
  'uploaded': 'a message, not a rule (a failed upload)',
};

/// The static methods of `abstract final class Rules`, from its source.
Set<String> _rulesStatics() {
  final unit = parseString(
    content: File('lib/src/validation/rules.dart').readAsStringSync(),
  ).unit;
  final rules = unit.declarations.whereType<ClassDeclaration>().singleWhere(
    (c) => c.namePart.typeName.lexeme == 'Rules',
  );
  return {
    for (final member in rules.body.members.whereType<MethodDeclaration>())
      if (member.isStatic) member.name.lexeme,
  };
}

/// One sample call per `Rules` static.
Map<String, Rule Function()> _sampleBuilders() => {
  'gt': () => Rules.gt('b'),
  'gte': () => Rules.gte('b'),
  'lt': () => Rules.lt('b'),
  'lte': () => Rules.lte('b'),
  'decimal': () => Rules.decimal(2),
  'multipleOf': () => Rules.multipleOf(5),
  'minDigits': () => Rules.minDigits(2),
  'maxDigits': () => Rules.maxDigits(2),
  'dateEquals': () => Rules.dateEquals('today'),
  'timezone': Rules.timezone,
  'requiredWithAll': () => Rules.requiredWithAll(['b']),
  'requiredWithoutAll': () => Rules.requiredWithoutAll(['b']),
  'requiredIfAccepted': () => Rules.requiredIfAccepted('b'),
  'presentIf': () => Rules.presentIf('b', ['x']),
  'prohibitedIf': () => Rules.prohibitedIf('b', ['x']),
  'prohibitedUnless': () => Rules.prohibitedUnless('b', ['x']),
  'prohibits': () => Rules.prohibits(['b']),
  'missing': Rules.missing,
  'missingIf': () => Rules.missingIf('b', ['x']),
  'missingUnless': () => Rules.missingUnless('b', ['x']),
  'missingWith': () => Rules.missingWith(['b']),
  'missingWithAll': () => Rules.missingWithAll(['b']),
  'presentUnless': () => Rules.presentUnless('b', ['x']),
  'presentWith': () => Rules.presentWith(['b']),
  'presentWithAll': () => Rules.presentWithAll(['b']),
  'prohibitedIfAccepted': () => Rules.prohibitedIfAccepted('b'),
  'prohibitedIfDeclined': () => Rules.prohibitedIfDeclined('b'),
  'requiredIfDeclined': () => Rules.requiredIfDeclined('b'),
  'requiredArrayKeys': () => Rules.requiredArrayKeys(['x']),
  'contains': () => Rules.contains(['x']),
  'doesntContain': () => Rules.doesntContain(['x']),
  'doesntStartWith': () => Rules.doesntStartWith(['x']),
  'doesntEndWith': () => Rules.doesntEndWith(['x']),
  'inArray': () => Rules.inArray('items.*'),
  'inArrayKeys': () => Rules.inArrayKeys(['x']),
  'arrayKeys': () => Rules.arrayKeys(['x']),
  'hexColor': Rules.hexColor,
  'macAddress': Rules.macAddress,
  'encoding': () => Rules.encoding('UTF-8'),
  'base64': Rules.base64,
  'exclude': Rules.exclude,
  'excludeIf': () => Rules.excludeIf('b', ['x']),
  'excludeUnless': () => Rules.excludeUnless('b', ['x']),
  'excludeWith': () => Rules.excludeWith('b'),
  'excludeWithout': () => Rules.excludeWithout('b'),
  'enum_': () => Rules.enum_(_Status.values),
  'required': Rules.required,
  'nullable': Rules.nullable,
  'sometimes': Rules.sometimes,
  'bail': Rules.bail,
  'present': Rules.present,
  'filled': Rules.filled,
  'prohibited': Rules.prohibited,
  'requiredIf': () => Rules.requiredIf('b', 'x'),
  'requiredUnless': () => Rules.requiredUnless('b', 'x'),
  'requiredIfIn': () => Rules.requiredIfIn('b', ['x', 'y']),
  'requiredUnlessIn': () => Rules.requiredUnlessIn('b', ['x', 'y']),
  'accepted': Rules.accepted,
  'acceptedIf': () => Rules.acceptedIf('b', ['x']),
  'declined': Rules.declined,
  'declinedIf': () => Rules.declinedIf('b', ['x']),
  'requiredWith': () => Rules.requiredWith(['b']),
  'requiredWithout': () => Rules.requiredWithout(['b']),
  'string': Rules.string,
  'integer': Rules.integer,
  'numeric': Rules.numeric,
  'boolean': Rules.boolean,
  'array': Rules.array,
  'list': Rules.list,
  'map': Rules.map,
  'email': Rules.email,
  'url': Rules.url,
  'activeUrl': Rules.activeUrl,
  'currentPassword': Rules.currentPassword,
  'can': () => Rules.can('update'),
  'dimensions': () => Rules.dimensions(minWidth: 1),
  'file': Rules.file,
  'image': Rules.image,
  'mimes': () => Rules.mimes(['pdf']),
  'mimetypes': () => Rules.mimetypes(['text/plain']),
  'extensions': () => Rules.extensions(['pdf']),
  'uuid': Rules.uuid,
  'ulid': Rules.ulid,
  'ip': Rules.ip,
  'ipv4': Rules.ipv4,
  'ipv6': Rules.ipv6,
  'json': Rules.json,
  'alpha': Rules.alpha,
  'alphaNum': Rules.alphaNum,
  'alphaDash': Rules.alphaDash,
  'ascii': Rules.ascii,
  'lowercase': Rules.lowercase,
  'uppercase': Rules.uppercase,
  'regex': () => Rules.regex(RegExp('x')),
  'notRegex': () => Rules.notRegex(RegExp('x')),
  'min': () => Rules.min(1),
  'max': () => Rules.max(1),
  'between': () => Rules.between(1, 2),
  'size': () => Rules.size(1),
  'digits': () => Rules.digits(1),
  'digitsBetween': () => Rules.digitsBetween(1, 2),
  'inList': () => Rules.inList(['x']),
  'notIn': () => Rules.notIn(['x']),
  'enumValues': () => Rules.enumValues(_Status.values),
  'distinct': Rules.distinct,
  'confirmed': Rules.confirmed,
  'same': () => Rules.same('b'),
  'different': () => Rules.different('b'),
  'startsWith': () => Rules.startsWith(['x']),
  'endsWith': () => Rules.endsWith(['x']),
  'date': Rules.date,
  'dateFormat': () => Rules.dateFormat(['Y-m-d']),
  'after': () => Rules.after('today'),
  'afterOrEqual': () => Rules.afterOrEqual('today'),
  'before': () => Rules.before('today'),
  'beforeOrEqual': () => Rules.beforeOrEqual('today'),
  'unique': () => Rules.unique('users'),
  'exists': () => Rules.exists('users'),
  'password': Rules.password,
  'custom': () => Rules.custom((ValidationContext c) => null),
  'when': () => Rules.when(true, [Rules.string()]),
  'whenInput': () => Rules.whenInput((input) => true, [Rules.string()]),
  'unless': () => Rules.unless(true, [Rules.string()]),
  'unlessInput': () => Rules.unlessInput((input) => true, [Rules.string()]),
  'forEach': () => Rules.forEach((item) => [Rules.string()]),
  'forEachNested': () => Rules.forEachNested(
    (item) => {
      'a': [Rules.string()],
    },
  ),
  'anyOf': () => Rules.anyOf([
    [Rules.string()],
  ]),
  'anyOfKeyed': () => Rules.anyOfKeyed([
    {
      'a': [Rules.string()],
    },
  ]),
};
