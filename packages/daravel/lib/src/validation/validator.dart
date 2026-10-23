import 'dart:async';

import '../foundation/container.dart';
import 'messages.dart';
import 'rule.dart';
import 'rule_parser.dart';
import 'validated_data.dart';
import 'validation_exception.dart';

/// Validates a map of input against rules (BLUEPRINT_V2 §7.4).
///
/// Rule keys may contain `*` wildcards (`items.*.id`); each concrete
/// attribute present in the input is validated separately and errors are
/// reported under the concrete path (`items.2.id`). Semantics follow
/// Laravel: implicit rules (`required*`, `present`, `prohibited`) always run;
/// other rules are skipped for absent attributes and empty strings;
/// `nullable` stops on `null`; `sometimes` skips absent attributes; `bail`
/// stops after the first failure of an attribute.
final class Validator {
  Validator(
    this.data,
    Map<String, Object> rules, {
    this.messages = const <String, String>{},
    this.attributes = const <String, String>{},
    this.container,
    this.locale = 'en',
    this.stopOnFirstFailure = false,
  }) : rules = RuleParser.parseMap(rules);

  final Map<String, Object?> data;
  final Map<String, List<Rule>> rules;

  /// Custom messages keyed by `attribute.rule` or `rule`.
  final Map<String, String> messages;

  /// Display names for attributes (`email` → `email address`).
  final Map<String, String> attributes;

  final Container? container;
  final String locale;
  final bool stopOnFirstFailure;

  final List<FutureOr<void> Function(Validator validator)> _after = [];
  Map<String, List<String>>? _errors;

  /// Registers a hook run after all rules (may add errors via [addError]).
  Validator after(FutureOr<void> Function(Validator validator) hook) {
    _after.add(hook);
    return this;
  }

  /// Adds a literal error message for [attribute].
  void addError(String attribute, String message) =>
      (_errors ??= {}).putIfAbsent(attribute, () => []).add(message);

  /// Errors from the last [run] (empty when valid).
  Map<String, List<String>> get errors => Map.unmodifiable(_errors ?? const {});

  /// Runs validation and returns the errors (empty when valid).
  Future<Map<String, List<String>>> run() async {
    _errors = {};
    outer:
    for (final entry in rules.entries) {
      for (final attribute in expandPattern(data, entry.key)) {
        await _validateAttribute(attribute, entry.key, entry.value);
        if (stopOnFirstFailure && _errors!.isNotEmpty) {
          break outer;
        }
      }
    }
    for (final hook in _after) {
      await hook(this);
    }
    return errors;
  }

  Future<bool> passes() async => (await run()).isEmpty;

  Future<bool> fails() async => !(await passes());

  /// Runs validation and throws [ValidationException] on failure; returns
  /// only the validated attributes otherwise.
  Future<ValidatedData> validate() async {
    final errors = await run();
    if (errors.isNotEmpty) {
      throw ValidationException(errors);
    }
    return validated();
  }

  /// The subset of [data] covered by rules, keeping nested structure.
  ValidatedData validated() {
    final result = <String, Object?>{};
    for (final pattern in rules.keys) {
      for (final attribute in expandPattern(data, pattern)) {
        if (!ValidationContext.exists(data, attribute)) {
          continue;
        }
        _assign(
          result,
          attribute.split('.'),
          ValidationContext.dig(data, attribute),
        );
      }
    }
    return ValidatedData(result);
  }

  Future<void> _validateAttribute(
    String attribute,
    String pattern,
    List<Rule> ruleList,
  ) async {
    final present = ValidationContext.exists(data, attribute);
    final value = present ? ValidationContext.dig(data, attribute) : null;
    final nullable = ruleList.any((r) => r is NullableRule);
    final sometimes = ruleList.any((r) => r is SometimesRule);
    final bail = ruleList.any((r) => r is BailRule);

    if (sometimes && !present) {
      return;
    }
    final isEmptyString = value is String && value.trim().isEmpty;

    for (final rule in ruleList) {
      if (rule is NullableRule || rule is SometimesRule || rule is BailRule) {
        continue;
      }
      if (!rule.implicit) {
        if (!present || isEmptyString) {
          continue;
        }
        if (value == null && nullable) {
          continue;
        }
      }
      final context = ValidationContext(
        attribute: attribute,
        pattern: pattern,
        value: value,
        present: present,
        data: data,
        container: container,
        locale: locale,
      );
      final failure = await rule.passes(context);
      if (failure != null) {
        addError(attribute, _message(failure, attribute, pattern, rule));
        if (bail) {
          return;
        }
      }
    }
  }

  String _message(String key, String attribute, String pattern, Rule rule) {
    final display =
        attributes[pattern] ??
        attributes[attribute] ??
        attribute.replaceAll('_', ' ');
    final override =
        messages['$attribute.${rule.name}'] ??
        messages['$pattern.${rule.name}'] ??
        messages[rule.name] ??
        messages[key];
    final overrides = <String, String>{key: ?override};
    return ValidationMessages.resolve(
      key,
      locale: locale,
      attribute: display,
      parameters: rule.parameters,
      overrides: overrides,
    );
  }

  static void _assign(
    Map<String, Object?> target,
    List<String> path,
    Object? value,
  ) {
    Object current = target;
    for (var i = 0; i < path.length; i++) {
      final segment = path[i];
      final last = i == path.length - 1;
      final index = int.tryParse(segment);
      if (current is Map<String, Object?>) {
        if (last) {
          current[segment] = value;
          return;
        }
        final nextIsIndex = int.tryParse(path[i + 1]) != null;
        final next = current[segment] ??= nextIsIndex
            ? <Object?>[]
            : <String, Object?>{};
        current = next;
      } else if (current is List<Object?> && index != null) {
        while (current.length <= index) {
          current.add(null);
        }
        if (last) {
          current[index] = value;
          return;
        }
        final nextIsIndex = int.tryParse(path[i + 1]) != null;
        final next = current[index] ??= nextIsIndex
            ? <Object?>[]
            : <String, Object?>{};
        current = next;
      } else {
        return;
      }
    }
  }

  /// Expands a wildcard [pattern] against [data] into concrete attributes.
  /// Patterns without `*` are returned unchanged.
  static List<String> expandPattern(Object? data, String pattern) {
    if (!pattern.contains('*')) {
      return [pattern];
    }
    final segments = pattern.split('.');
    final results = <String>[];
    void walk(Object? current, int index, String prefix) {
      if (index == segments.length) {
        results.add(prefix);
        return;
      }
      final segment = segments[index];
      final next = prefix.isEmpty ? '' : '$prefix.';
      if (segment == '*') {
        if (current is List<Object?>) {
          for (var i = 0; i < current.length; i++) {
            walk(current[i], index + 1, '$next$i');
          }
        } else if (current is Map<Object?, Object?>) {
          for (final key in current.keys) {
            walk(current[key], index + 1, '$next$key');
          }
        }
        return;
      }
      final child = switch (current) {
        Map<Object?, Object?>() => current[segment],
        List<Object?>()
            when int.tryParse(segment) != null &&
                int.parse(segment) < current.length =>
          current[int.parse(segment)],
        _ => null,
      };
      walk(child, index + 1, '$next$segment');
    }

    walk(data, 0, '');
    return results;
  }
}
