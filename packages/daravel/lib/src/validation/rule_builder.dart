import 'dart:async';

import 'rule.dart';
import 'rules.dart';

/// Rules written as a chain, typed and checked by the compiler:
///
/// ```dart
/// .rules({
///   'email': Rules.required().string().email().max(255).unique('users'),
///   'age': Rules.nullable().integer().min(18),
/// })
/// ```
///
/// Any `Rules.x()` starts a chain (through [RuleChain]); each step appends
/// the rule of the same name in `Rules`. A builder is accepted wherever a
/// rule list is, alongside DSL strings.
final class RuleBuilder {
  /// A chain starting with [rules].
  RuleBuilder([Iterable<Rule> rules = const []]) : _rules = [...rules];

  final List<Rule> _rules;

  /// The rules in order.
  List<Rule> toList() => List.unmodifiable(_rules);

  RuleBuilder _add(Rule rule) {
    _rules.add(rule);
    return this;
  }

  /// Appends any [rule] (a custom one, or one built elsewhere).
  RuleBuilder rule(Rule rule) => _add(rule);

  /// Appends [Rules.required].
  RuleBuilder required() => _add(Rules.required());

  /// Appends [Rules.nullable].
  RuleBuilder nullable() => _add(Rules.nullable());

  /// Appends [Rules.sometimes].
  RuleBuilder sometimes() => _add(Rules.sometimes());

  /// Appends [Rules.bail].
  RuleBuilder bail() => _add(Rules.bail());

  /// Appends [Rules.present].
  RuleBuilder present() => _add(Rules.present());

  /// Appends [Rules.filled].
  RuleBuilder filled() => _add(Rules.filled());

  /// Appends [Rules.prohibited].
  RuleBuilder prohibited() => _add(Rules.prohibited());

  /// Appends [Rules.accepted].
  RuleBuilder accepted() => _add(Rules.accepted());

  /// Appends [Rules.acceptedIf].
  RuleBuilder acceptedIf(String other, List<String> values) =>
      _add(Rules.acceptedIf(other, values));

  /// Appends [Rules.declined].
  RuleBuilder declined() => _add(Rules.declined());

  /// Appends [Rules.declinedIf].
  RuleBuilder declinedIf(String other, List<String> values) =>
      _add(Rules.declinedIf(other, values));

  /// Appends [Rules.requiredIf].
  RuleBuilder requiredIf(String other, Object? value) =>
      _add(Rules.requiredIf(other, value));

  /// Appends [Rules.requiredUnless].
  RuleBuilder requiredUnless(String other, Object? value) =>
      _add(Rules.requiredUnless(other, value));

  /// Appends [Rules.requiredWith].
  RuleBuilder requiredWith(List<String> others) =>
      _add(Rules.requiredWith(others));

  /// Appends [Rules.requiredWithout].
  RuleBuilder requiredWithout(List<String> others) =>
      _add(Rules.requiredWithout(others));

  /// Appends [Rules.string].
  RuleBuilder string() => _add(Rules.string());

  /// Appends [Rules.integer].
  RuleBuilder integer() => _add(Rules.integer());

  /// Appends [Rules.numeric].
  RuleBuilder numeric() => _add(Rules.numeric());

  /// Appends [Rules.boolean].
  RuleBuilder boolean() => _add(Rules.boolean());

  /// Appends [Rules.array].
  RuleBuilder array([List<String>? keys]) => _add(Rules.array(keys));

  /// Appends [Rules.list].
  RuleBuilder list() => _add(Rules.list());

  /// Appends [Rules.map].
  RuleBuilder map() => _add(Rules.map());

  /// Appends [Rules.email].
  RuleBuilder email() => _add(Rules.email());

  /// Appends [Rules.url].
  RuleBuilder url() => _add(Rules.url());

  /// Appends [Rules.file].
  RuleBuilder file() => _add(Rules.file());

  /// Appends [Rules.image].
  RuleBuilder image({bool allowSvg = false}) =>
      _add(Rules.image(allowSvg: allowSvg));

  /// Appends [Rules.mimes].
  RuleBuilder mimes(List<String> extensions) => _add(Rules.mimes(extensions));

  /// Appends [Rules.mimetypes].
  RuleBuilder mimetypes(List<String> types) => _add(Rules.mimetypes(types));

  /// Appends [Rules.extensions].
  RuleBuilder extensions(List<String> extensions) =>
      _add(Rules.extensions(extensions));

  /// Appends [Rules.uuid].
  RuleBuilder uuid() => _add(Rules.uuid());

  /// Appends [Rules.ulid].
  RuleBuilder ulid() => _add(Rules.ulid());

  /// Appends [Rules.ip].
  RuleBuilder ip() => _add(Rules.ip());

  /// Appends [Rules.ipv4].
  RuleBuilder ipv4() => _add(Rules.ipv4());

  /// Appends [Rules.ipv6].
  RuleBuilder ipv6() => _add(Rules.ipv6());

  /// Appends [Rules.json].
  RuleBuilder json() => _add(Rules.json());

  /// Appends [Rules.alpha].
  RuleBuilder alpha() => _add(Rules.alpha());

  /// Appends [Rules.alphaNum].
  RuleBuilder alphaNum() => _add(Rules.alphaNum());

  /// Appends [Rules.alphaDash].
  RuleBuilder alphaDash() => _add(Rules.alphaDash());

  /// Appends [Rules.ascii].
  RuleBuilder ascii() => _add(Rules.ascii());

  /// Appends [Rules.lowercase].
  RuleBuilder lowercase() => _add(Rules.lowercase());

  /// Appends [Rules.uppercase].
  RuleBuilder uppercase() => _add(Rules.uppercase());

  /// Appends [Rules.regex].
  RuleBuilder regex(RegExp pattern) => _add(Rules.regex(pattern));

  /// Appends [Rules.notRegex].
  RuleBuilder notRegex(RegExp pattern) => _add(Rules.notRegex(pattern));

  /// Appends [Rules.min].
  RuleBuilder min(num value) => _add(Rules.min(value));

  /// Appends [Rules.max].
  RuleBuilder max(num value) => _add(Rules.max(value));

  /// Appends [Rules.between].
  RuleBuilder between(num min, num max) => _add(Rules.between(min, max));

  /// Appends [Rules.size].
  RuleBuilder size(num value) => _add(Rules.size(value));

  /// Appends [Rules.digits].
  RuleBuilder digits(int length) => _add(Rules.digits(length));

  /// Appends [Rules.digitsBetween].
  RuleBuilder digitsBetween(int min, int max) =>
      _add(Rules.digitsBetween(min, max));

  /// Appends [Rules.inList].
  RuleBuilder inList(List<Object?> values) => _add(Rules.inList(values));

  /// Appends [Rules.notIn].
  RuleBuilder notIn(List<Object?> values) => _add(Rules.notIn(values));

  /// Appends [Rules.enumValues].
  RuleBuilder enumValues<E extends Enum>(List<E> values) =>
      _add(Rules.enumValues(values));

  /// Appends [Rules.distinct].
  RuleBuilder distinct() => _add(Rules.distinct());

  /// Appends [Rules.confirmed].
  RuleBuilder confirmed([String? field]) => _add(Rules.confirmed(field));

  /// Appends [Rules.same].
  RuleBuilder same(String other) => _add(Rules.same(other));

  /// Appends [Rules.different].
  RuleBuilder different(String other) => _add(Rules.different(other));

  /// Appends [Rules.startsWith].
  RuleBuilder startsWith(List<String> prefixes) =>
      _add(Rules.startsWith(prefixes));

  /// Appends [Rules.endsWith].
  RuleBuilder endsWith(List<String> suffixes) => _add(Rules.endsWith(suffixes));

  /// Appends [Rules.date].
  RuleBuilder date() => _add(Rules.date());

  /// Appends [Rules.after].
  RuleBuilder after(String dateOrField) => _add(Rules.after(dateOrField));

  /// Appends [Rules.afterOrEqual].
  RuleBuilder afterOrEqual(String dateOrField) =>
      _add(Rules.afterOrEqual(dateOrField));

  /// Appends [Rules.before].
  RuleBuilder before(String dateOrField) => _add(Rules.before(dateOrField));

  /// Appends [Rules.beforeOrEqual].
  RuleBuilder beforeOrEqual(String dateOrField) =>
      _add(Rules.beforeOrEqual(dateOrField));

  /// Appends [Rules.unique].
  RuleBuilder unique(
    String table, [
    String? column,
    Object? ignore,
    String idColumn = 'id',
  ]) => _add(Rules.unique(table, column, ignore, idColumn));

  /// Appends [Rules.exists].
  RuleBuilder exists(String table, [String? column]) =>
      _add(Rules.exists(table, column));

  /// Appends [Rules.password].
  RuleBuilder password({
    int min = 8,
    bool letters = false,
    bool mixedCase = false,
    bool numbers = false,
    bool symbols = false,
  }) => _add(
    Rules.password(
      min: min,
      letters: letters,
      mixedCase: mixedCase,
      numbers: numbers,
      symbols: symbols,
    ),
  );

  /// Appends [Rules.custom].
  RuleBuilder custom(
    FutureOr<String?> Function(ValidationContext context) check, {
    String name = 'custom',
  }) => _add(Rules.custom(check, name: name));
}

/// Starts a [RuleBuilder] from any rule: `Rules.required().email()`.
extension RuleChain on Rule {
  RuleBuilder get _chain => RuleBuilder([this]);

  /// This rule followed by [Rules.required].
  RuleBuilder required() => _chain.required();

  /// This rule followed by [Rules.nullable].
  RuleBuilder nullable() => _chain.nullable();

  /// This rule followed by [Rules.sometimes].
  RuleBuilder sometimes() => _chain.sometimes();

  /// This rule followed by [Rules.bail].
  RuleBuilder bail() => _chain.bail();

  /// This rule followed by [Rules.present].
  RuleBuilder present() => _chain.present();

  /// This rule followed by [Rules.filled].
  RuleBuilder filled() => _chain.filled();

  /// This rule followed by [Rules.prohibited].
  RuleBuilder prohibited() => _chain.prohibited();

  /// This rule followed by [Rules.accepted].
  RuleBuilder accepted() => _chain.accepted();

  /// This rule followed by [Rules.acceptedIf].
  RuleBuilder acceptedIf(String other, List<String> values) =>
      _chain.acceptedIf(other, values);

  /// This rule followed by [Rules.declined].
  RuleBuilder declined() => _chain.declined();

  /// This rule followed by [Rules.declinedIf].
  RuleBuilder declinedIf(String other, List<String> values) =>
      _chain.declinedIf(other, values);

  /// This rule followed by [Rules.requiredIf].
  RuleBuilder requiredIf(String other, Object? value) =>
      _chain.requiredIf(other, value);

  /// This rule followed by [Rules.requiredUnless].
  RuleBuilder requiredUnless(String other, Object? value) =>
      _chain.requiredUnless(other, value);

  /// This rule followed by [Rules.requiredWith].
  RuleBuilder requiredWith(List<String> others) => _chain.requiredWith(others);

  /// This rule followed by [Rules.requiredWithout].
  RuleBuilder requiredWithout(List<String> others) =>
      _chain.requiredWithout(others);

  /// This rule followed by [Rules.string].
  RuleBuilder string() => _chain.string();

  /// This rule followed by [Rules.integer].
  RuleBuilder integer() => _chain.integer();

  /// This rule followed by [Rules.numeric].
  RuleBuilder numeric() => _chain.numeric();

  /// This rule followed by [Rules.boolean].
  RuleBuilder boolean() => _chain.boolean();

  /// This rule followed by [Rules.list].
  RuleBuilder list() => _chain.list();

  /// This rule followed by [Rules.map].
  RuleBuilder map() => _chain.map();

  /// This rule followed by [Rules.email].
  RuleBuilder email() => _chain.email();

  /// This rule followed by [Rules.url].
  RuleBuilder url() => _chain.url();

  /// This rule followed by [Rules.file].
  RuleBuilder file() => _chain.file();

  /// This rule followed by [Rules.image].
  RuleBuilder image({bool allowSvg = false}) =>
      _chain.image(allowSvg: allowSvg);

  /// This rule followed by [Rules.mimes].
  RuleBuilder mimes(List<String> extensions) => _chain.mimes(extensions);

  /// This rule followed by [Rules.mimetypes].
  RuleBuilder mimetypes(List<String> types) => _chain.mimetypes(types);

  /// This rule followed by [Rules.extensions].
  RuleBuilder extensions(List<String> extensions) =>
      _chain.extensions(extensions);

  /// This rule followed by [Rules.uuid].
  RuleBuilder uuid() => _chain.uuid();

  /// This rule followed by [Rules.ulid].
  RuleBuilder ulid() => _chain.ulid();

  /// This rule followed by [Rules.ip].
  RuleBuilder ip() => _chain.ip();

  /// This rule followed by [Rules.ipv4].
  RuleBuilder ipv4() => _chain.ipv4();

  /// This rule followed by [Rules.ipv6].
  RuleBuilder ipv6() => _chain.ipv6();

  /// This rule followed by [Rules.json].
  RuleBuilder json() => _chain.json();

  /// This rule followed by [Rules.alpha].
  RuleBuilder alpha() => _chain.alpha();

  /// This rule followed by [Rules.alphaNum].
  RuleBuilder alphaNum() => _chain.alphaNum();

  /// This rule followed by [Rules.alphaDash].
  RuleBuilder alphaDash() => _chain.alphaDash();

  /// This rule followed by [Rules.ascii].
  RuleBuilder ascii() => _chain.ascii();

  /// This rule followed by [Rules.lowercase].
  RuleBuilder lowercase() => _chain.lowercase();

  /// This rule followed by [Rules.uppercase].
  RuleBuilder uppercase() => _chain.uppercase();

  /// This rule followed by [Rules.regex].
  RuleBuilder regex(RegExp pattern) => _chain.regex(pattern);

  /// This rule followed by [Rules.notRegex].
  RuleBuilder notRegex(RegExp pattern) => _chain.notRegex(pattern);

  /// This rule followed by [Rules.min].
  RuleBuilder min(num value) => _chain.min(value);

  /// This rule followed by [Rules.max].
  RuleBuilder max(num value) => _chain.max(value);

  /// This rule followed by [Rules.between].
  RuleBuilder between(num min, num max) => _chain.between(min, max);

  /// This rule followed by [Rules.size].
  RuleBuilder size(num value) => _chain.size(value);

  /// This rule followed by [Rules.digits].
  RuleBuilder digits(int length) => _chain.digits(length);

  /// This rule followed by [Rules.digitsBetween].
  RuleBuilder digitsBetween(int min, int max) => _chain.digitsBetween(min, max);

  /// This rule followed by [Rules.inList].
  RuleBuilder inList(List<Object?> values) => _chain.inList(values);

  /// This rule followed by [Rules.notIn].
  RuleBuilder notIn(List<Object?> values) => _chain.notIn(values);

  /// This rule followed by [Rules.enumValues].
  RuleBuilder enumValues<E extends Enum>(List<E> values) =>
      _chain.enumValues(values);

  /// This rule followed by [Rules.distinct].
  RuleBuilder distinct() => _chain.distinct();

  /// This rule followed by [Rules.confirmed].
  RuleBuilder confirmed([String? field]) => _chain.confirmed(field);

  /// This rule followed by [Rules.same].
  RuleBuilder same(String other) => _chain.same(other);

  /// This rule followed by [Rules.different].
  RuleBuilder different(String other) => _chain.different(other);

  /// This rule followed by [Rules.startsWith].
  RuleBuilder startsWith(List<String> prefixes) => _chain.startsWith(prefixes);

  /// This rule followed by [Rules.endsWith].
  RuleBuilder endsWith(List<String> suffixes) => _chain.endsWith(suffixes);

  /// This rule followed by [Rules.date].
  RuleBuilder date() => _chain.date();

  /// This rule followed by [Rules.after].
  RuleBuilder after(String dateOrField) => _chain.after(dateOrField);

  /// This rule followed by [Rules.afterOrEqual].
  RuleBuilder afterOrEqual(String dateOrField) =>
      _chain.afterOrEqual(dateOrField);

  /// This rule followed by [Rules.before].
  RuleBuilder before(String dateOrField) => _chain.before(dateOrField);

  /// This rule followed by [Rules.beforeOrEqual].
  RuleBuilder beforeOrEqual(String dateOrField) =>
      _chain.beforeOrEqual(dateOrField);

  /// This rule followed by [Rules.unique].
  RuleBuilder unique(
    String table, [
    String? column,
    Object? ignore,
    String idColumn = 'id',
  ]) => _chain.unique(table, column, ignore, idColumn);

  /// This rule followed by [Rules.exists].
  RuleBuilder exists(String table, [String? column]) =>
      _chain.exists(table, column);

  /// This rule followed by [Rules.password].
  RuleBuilder password({
    int min = 8,
    bool letters = false,
    bool mixedCase = false,
    bool numbers = false,
    bool symbols = false,
  }) => _chain.password(
    min: min,
    letters: letters,
    mixedCase: mixedCase,
    numbers: numbers,
    symbols: symbols,
  );

  /// This rule followed by [Rules.custom].
  RuleBuilder custom(
    FutureOr<String?> Function(ValidationContext context) check, {
    String name = 'custom',
  }) => _chain.custom(check, name: name);
}
