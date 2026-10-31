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

  RuleBuilder required() => _add(Rules.required());
  RuleBuilder nullable() => _add(Rules.nullable());
  RuleBuilder sometimes() => _add(Rules.sometimes());
  RuleBuilder bail() => _add(Rules.bail());
  RuleBuilder present() => _add(Rules.present());
  RuleBuilder filled() => _add(Rules.filled());
  RuleBuilder prohibited() => _add(Rules.prohibited());
  RuleBuilder accepted() => _add(Rules.accepted());
  RuleBuilder acceptedIf(String other, List<String> values) =>
      _add(Rules.acceptedIf(other, values));
  RuleBuilder declined() => _add(Rules.declined());
  RuleBuilder declinedIf(String other, List<String> values) =>
      _add(Rules.declinedIf(other, values));
  RuleBuilder requiredIf(String other, Object? value) =>
      _add(Rules.requiredIf(other, value));
  RuleBuilder requiredUnless(String other, Object? value) =>
      _add(Rules.requiredUnless(other, value));
  RuleBuilder requiredWith(List<String> others) =>
      _add(Rules.requiredWith(others));
  RuleBuilder requiredWithout(List<String> others) =>
      _add(Rules.requiredWithout(others));

  RuleBuilder string() => _add(Rules.string());
  RuleBuilder integer() => _add(Rules.integer());
  RuleBuilder numeric() => _add(Rules.numeric());
  RuleBuilder boolean() => _add(Rules.boolean());
  RuleBuilder list() => _add(Rules.list());
  RuleBuilder map() => _add(Rules.map());
  RuleBuilder email() => _add(Rules.email());
  RuleBuilder url() => _add(Rules.url());
  RuleBuilder file() => _add(Rules.file());
  RuleBuilder image({bool allowSvg = false}) =>
      _add(Rules.image(allowSvg: allowSvg));
  RuleBuilder mimes(List<String> extensions) => _add(Rules.mimes(extensions));
  RuleBuilder mimetypes(List<String> types) => _add(Rules.mimetypes(types));
  RuleBuilder extensions(List<String> extensions) =>
      _add(Rules.extensions(extensions));
  RuleBuilder uuid() => _add(Rules.uuid());
  RuleBuilder ulid() => _add(Rules.ulid());
  RuleBuilder ip() => _add(Rules.ip());
  RuleBuilder ipv4() => _add(Rules.ipv4());
  RuleBuilder ipv6() => _add(Rules.ipv6());
  RuleBuilder json() => _add(Rules.json());
  RuleBuilder alpha() => _add(Rules.alpha());
  RuleBuilder alphaNum() => _add(Rules.alphaNum());
  RuleBuilder alphaDash() => _add(Rules.alphaDash());
  RuleBuilder ascii() => _add(Rules.ascii());
  RuleBuilder lowercase() => _add(Rules.lowercase());
  RuleBuilder uppercase() => _add(Rules.uppercase());
  RuleBuilder regex(RegExp pattern) => _add(Rules.regex(pattern));
  RuleBuilder notRegex(RegExp pattern) => _add(Rules.notRegex(pattern));

  RuleBuilder min(num value) => _add(Rules.min(value));
  RuleBuilder max(num value) => _add(Rules.max(value));
  RuleBuilder between(num min, num max) => _add(Rules.between(min, max));
  RuleBuilder size(num value) => _add(Rules.size(value));
  RuleBuilder digits(int length) => _add(Rules.digits(length));
  RuleBuilder digitsBetween(int min, int max) =>
      _add(Rules.digitsBetween(min, max));
  RuleBuilder inList(List<Object?> values) => _add(Rules.inList(values));
  RuleBuilder notIn(List<Object?> values) => _add(Rules.notIn(values));
  RuleBuilder enumValues<E extends Enum>(List<E> values) =>
      _add(Rules.enumValues(values));
  RuleBuilder distinct() => _add(Rules.distinct());
  RuleBuilder confirmed([String? field]) => _add(Rules.confirmed(field));
  RuleBuilder same(String other) => _add(Rules.same(other));
  RuleBuilder different(String other) => _add(Rules.different(other));
  RuleBuilder startsWith(List<String> prefixes) =>
      _add(Rules.startsWith(prefixes));
  RuleBuilder endsWith(List<String> suffixes) => _add(Rules.endsWith(suffixes));

  RuleBuilder date() => _add(Rules.date());
  RuleBuilder after(String dateOrField) => _add(Rules.after(dateOrField));
  RuleBuilder afterOrEqual(String dateOrField) =>
      _add(Rules.afterOrEqual(dateOrField));
  RuleBuilder before(String dateOrField) => _add(Rules.before(dateOrField));
  RuleBuilder beforeOrEqual(String dateOrField) =>
      _add(Rules.beforeOrEqual(dateOrField));

  RuleBuilder unique(
    String table, [
    String? column,
    Object? ignore,
    String idColumn = 'id',
  ]) => _add(Rules.unique(table, column, ignore, idColumn));
  RuleBuilder exists(String table, [String? column]) =>
      _add(Rules.exists(table, column));
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
  RuleBuilder custom(
    FutureOr<String?> Function(ValidationContext context) check, {
    String name = 'custom',
  }) => _add(Rules.custom(check, name: name));
}

/// Starts a [RuleBuilder] from any rule: `Rules.required().email()`.
extension RuleChain on Rule {
  RuleBuilder get _chain => RuleBuilder([this]);

  RuleBuilder required() => _chain.required();
  RuleBuilder nullable() => _chain.nullable();
  RuleBuilder sometimes() => _chain.sometimes();
  RuleBuilder bail() => _chain.bail();
  RuleBuilder present() => _chain.present();
  RuleBuilder filled() => _chain.filled();
  RuleBuilder prohibited() => _chain.prohibited();
  RuleBuilder accepted() => _chain.accepted();
  RuleBuilder acceptedIf(String other, List<String> values) =>
      _chain.acceptedIf(other, values);
  RuleBuilder declined() => _chain.declined();
  RuleBuilder declinedIf(String other, List<String> values) =>
      _chain.declinedIf(other, values);
  RuleBuilder requiredIf(String other, Object? value) =>
      _chain.requiredIf(other, value);
  RuleBuilder requiredUnless(String other, Object? value) =>
      _chain.requiredUnless(other, value);
  RuleBuilder requiredWith(List<String> others) => _chain.requiredWith(others);
  RuleBuilder requiredWithout(List<String> others) =>
      _chain.requiredWithout(others);
  RuleBuilder string() => _chain.string();
  RuleBuilder integer() => _chain.integer();
  RuleBuilder numeric() => _chain.numeric();
  RuleBuilder boolean() => _chain.boolean();
  RuleBuilder list() => _chain.list();
  RuleBuilder map() => _chain.map();
  RuleBuilder email() => _chain.email();
  RuleBuilder url() => _chain.url();
  RuleBuilder file() => _chain.file();
  RuleBuilder image({bool allowSvg = false}) =>
      _chain.image(allowSvg: allowSvg);
  RuleBuilder mimes(List<String> extensions) => _chain.mimes(extensions);
  RuleBuilder mimetypes(List<String> types) => _chain.mimetypes(types);
  RuleBuilder extensions(List<String> extensions) =>
      _chain.extensions(extensions);
  RuleBuilder uuid() => _chain.uuid();
  RuleBuilder ulid() => _chain.ulid();
  RuleBuilder ip() => _chain.ip();
  RuleBuilder ipv4() => _chain.ipv4();
  RuleBuilder ipv6() => _chain.ipv6();
  RuleBuilder json() => _chain.json();
  RuleBuilder alpha() => _chain.alpha();
  RuleBuilder alphaNum() => _chain.alphaNum();
  RuleBuilder alphaDash() => _chain.alphaDash();
  RuleBuilder ascii() => _chain.ascii();
  RuleBuilder lowercase() => _chain.lowercase();
  RuleBuilder uppercase() => _chain.uppercase();
  RuleBuilder regex(RegExp pattern) => _chain.regex(pattern);
  RuleBuilder notRegex(RegExp pattern) => _chain.notRegex(pattern);
  RuleBuilder min(num value) => _chain.min(value);
  RuleBuilder max(num value) => _chain.max(value);
  RuleBuilder between(num min, num max) => _chain.between(min, max);
  RuleBuilder size(num value) => _chain.size(value);
  RuleBuilder digits(int length) => _chain.digits(length);
  RuleBuilder digitsBetween(int min, int max) => _chain.digitsBetween(min, max);
  RuleBuilder inList(List<Object?> values) => _chain.inList(values);
  RuleBuilder notIn(List<Object?> values) => _chain.notIn(values);
  RuleBuilder enumValues<E extends Enum>(List<E> values) =>
      _chain.enumValues(values);
  RuleBuilder distinct() => _chain.distinct();
  RuleBuilder confirmed([String? field]) => _chain.confirmed(field);
  RuleBuilder same(String other) => _chain.same(other);
  RuleBuilder different(String other) => _chain.different(other);
  RuleBuilder startsWith(List<String> prefixes) => _chain.startsWith(prefixes);
  RuleBuilder endsWith(List<String> suffixes) => _chain.endsWith(suffixes);
  RuleBuilder date() => _chain.date();
  RuleBuilder after(String dateOrField) => _chain.after(dateOrField);
  RuleBuilder afterOrEqual(String dateOrField) =>
      _chain.afterOrEqual(dateOrField);
  RuleBuilder before(String dateOrField) => _chain.before(dateOrField);
  RuleBuilder beforeOrEqual(String dateOrField) =>
      _chain.beforeOrEqual(dateOrField);
  RuleBuilder unique(
    String table, [
    String? column,
    Object? ignore,
    String idColumn = 'id',
  ]) => _chain.unique(table, column, ignore, idColumn);
  RuleBuilder exists(String table, [String? column]) =>
      _chain.exists(table, column);
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
  RuleBuilder custom(
    FutureOr<String?> Function(ValidationContext context) check, {
    String name = 'custom',
  }) => _chain.custom(check, name: name);
}
