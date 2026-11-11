import 'dart:async';

import 'rule.dart';
import 'validator.dart';

/// One element a [Rules.forEach] callback is asked about: its [value], its
/// concrete [attribute] (`items.2.id`), the [parent] that holds it (the
/// `items.2` map, null at the top level) and the whole [input].
typedef ForEachItem = ({
  Object? value,
  String attribute,
  Object? parent,
  Map<String, Object?> input,
});

/// A rule that stands for other rules, decided while validation runs
/// (Laravel's `ConditionalRules` and `CompilableRules`). The validator
/// expands it before any rule of the attribute runs, so its [passes] is
/// never called.
sealed class ExpandingRule extends Rule {
  const ExpandingRule();

  @override
  FutureOr<String?> passes(ValidationContext context) => throw StateError(
    'Rule "$name" stands for other rules; the Validator expands it before '
    'validation and never runs it.',
  );
}

/// `Rule::when` and `Rule::unless`: [rules] when the condition holds for
/// the input, [otherwise] when it does not. See [Rules.when].
final class ConditionalRule extends ExpandingRule {
  /// A condition over the whole input; use [Rules.when] or [Rules.unless].
  const ConditionalRule(this.name, this._condition, this.rules, this.otherwise);

  @override
  final String name;

  final bool Function(Map<String, Object?> input) _condition;

  /// The rules applied when the condition holds.
  final List<Rule> rules;

  /// The rules applied when it does not.
  final List<Rule> otherwise;

  /// The rules this stands for on [input].
  List<Rule> choose(Map<String, Object?> input) =>
      _condition(input) ? rules : otherwise;
}

/// `Rule::forEach`: rules built per element of an array attribute, from its
/// value. See [Rules.forEach] and [Rules.forEachNested].
final class ForEachRule extends ExpandingRule {
  /// Rules for the element itself; use [Rules.forEach].
  const ForEachRule.own(List<Rule> Function(ForEachItem item) rules)
    : _own = rules,
      _nested = null;

  /// Rules for keys of the element; use [Rules.forEachNested].
  const ForEachRule.nested(
    Map<String, List<Rule>> Function(ForEachItem item) rules,
  ) : _own = null,
      _nested = rules;

  final List<Rule> Function(ForEachItem item)? _own;
  final Map<String, List<Rule>> Function(ForEachItem item)? _nested;

  @override
  String get name => 'for_each';

  /// The rules of [item]: for the element itself (`own`) and for its keys
  /// (`nested`, `meta` → `items.2.meta`).
  ({List<Rule> own, Map<String, List<Rule>> nested}) compile(
    ForEachItem item,
  ) => (
    own: _own?.call(item) ?? const <Rule>[],
    nested: _nested?.call(item) ?? const <String, List<Rule>>{},
  );
}

/// `Rule::anyOf`: passes when the value passes one of the [alternatives].
/// See [Rules.anyOf].
final class AnyOfRule extends Rule {
  /// Rule lists for the value itself; use [Rules.anyOf].
  const AnyOfRule(List<List<Rule>> alternatives)
    : _plain = alternatives,
      _keyed = null;

  /// Rule maps for the keys of a map value; use [Rules.anyOfKeyed].
  const AnyOfRule.keyed(List<Map<String, List<Rule>>> alternatives)
    : _plain = null,
      _keyed = alternatives;

  final List<List<Rule>>? _plain;
  final List<Map<String, List<Rule>>>? _keyed;

  @override
  String get name => 'any_of';

  @override
  Future<String?> passes(ValidationContext context) async {
    final value = context.value;
    // As Laravel's AnyOf: each alternative is validated on the value alone,
    // in a validator of its own (a rule naming another field does not see
    // the rest of the input). A keyed alternative validates the keys of a
    // map value; any other value is wrapped, as Laravel's `[$value]`.
    final alternatives = <(Map<String, Object?>, Map<String, Object>)>[
      for (final rules in _plain ?? const <List<Rule>>[])
        ({'0': value}, {'0': rules}),
      for (final rules in _keyed ?? const <Map<String, List<Rule>>>[])
        (
          value is Map<String, Object?> ? value : {'0': value},
          {for (final MapEntry(:key, value: list) in rules.entries) key: list},
        ),
    ];
    for (final (data, rules) in alternatives) {
      final validator = Validator(
        data,
        rules,
        container: context.container,
        locale: context.locale,
      );
      if (await validator.passes()) {
        return null;
      }
    }
    return 'any_of';
  }
}
