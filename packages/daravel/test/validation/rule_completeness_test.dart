import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

enum _Status { draft }

/// Rule completeness in three directions (Blueprint #151, W9.4c), so a rule
/// that exists only as a string, only as a builder, or only in Laravel is
/// seen at once:
///
/// 1. every string name `RuleParser` accepts builds a rule of that name;
/// 2. every `Rules.*` builder makes a rule whose name the parser accepts
///    (or one of the named object-only rules);
/// 3. every rule of Laravel 13's `lang/en/validation.php` is known, or
///    named in [_laravelPending] with the slice that adds it.
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
  // closure).
  const objectOnly = <String>{'enum', 'custom'};

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
      _rulesStatics(),
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
}

/// Laravel 13 message keys without a Daravel string rule yet, and why.
/// Shrinks with each W9.4a pull request; empty when the slice is done.
const Map<String, String> _laravelPending = {
  'uploaded': 'a message, not a rule (a failed upload)',
  'any_of': 'W9.4a objects (Rule::anyOf)',
  'can': 'W9.4a external (Rule::can, needs the Gate)',
  'current_password': 'W9.4a external (needs the guard and Hash)',
  'active_url': 'W9.4a external (DNS)',
  'dimensions': 'W9.4a external (image headers)',
  'contains': 'W9.4a content',
  'doesnt_contain': 'W9.4a content',
  'doesnt_start_with': 'W9.4a content',
  'doesnt_end_with': 'W9.4a content',
  'in_array': 'W9.4a content',
  'in_array_keys': 'W9.4a content',
  'hex_color': 'W9.4a content',
  'mac_address': 'W9.4a content',
  'encoding': 'W9.4a content',
  'array_keys': 'W9.4a content (13.x only)',
  'base64': 'W9.4a content (13.x only)',
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
};
