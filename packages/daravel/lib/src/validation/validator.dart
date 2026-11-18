import 'dart:async';
import 'dart:math';

import '../foundation/container.dart';
import 'messages.dart';
import 'object_rules.dart';
import 'rule.dart';
import 'rule_parser.dart';
import 'rules.dart'
    show BooleanRule, ClosureRule, ExcludeRule, IntegerRule, NumericRule;
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
/// One attribute and the rules it runs, once `when`, `unless` and `forEach`
/// are expanded.
typedef _Planned = ({String attribute, String pattern, List<Rule> rules});

final class Validator {
  /// Validates [data] against [rules] (strings, [Rule]s or `RuleBuilder`s per
  /// key), with custom messages and attribute names.
  Validator(
    this.data,
    Map<String, Object> rules, {
    this.messages = const <String, String>{},
    this.attributes = const <String, String>{},
    this.container,
    this.locale = 'en',
    this.stopOnFirstFailure = false,
  }) : rules = RuleParser.parseMap(rules);

  /// The input being validated.
  final Map<String, Object?> data;

  /// The parsed rules by key.
  final Map<String, List<Rule>> rules;

  /// The attributes (and patterns) with a `boolean` rule after `when`,
  /// `unless` and `forEach` are expanded, as Laravel's
  /// `shouldConvertToBoolean` reads `$this->rules` once they are; filled
  /// by [run].
  Set<String> _booleans = const <String>{};

  /// Custom messages keyed by `attribute.rule` or `rule`.
  final Map<String, String> messages;

  /// Display names for attributes (`email` → `email address`).
  final Map<String, String> attributes;

  /// The container rules resolve services from (`unique`, `exists`).
  final Container? container;

  /// The locale of the messages.
  final String locale;

  /// Whether validation stops at the first failing attribute.
  final bool stopOnFirstFailure;

  final List<FutureOr<void> Function(Validator validator)> _after = [];
  Map<String, List<String>>? _errors;

  /// Registers a hook run after all rules (may add errors via [addError]).
  Validator after(FutureOr<void> Function(Validator validator) hook) {
    _after.add(hook);
    return this;
  }

  /// Adds a literal error message for [attribute].
  void addError(String attribute, String message) => (_errors ??= {})
      .putIfAbsent(_decodeKey(attribute), () => [])
      .add(message);

  /// Laravel's `Validator::$placeholderHash`: a `.` or `*` in a key of the
  /// data stands for itself, not for a level or a wildcard, so it is
  /// replaced while the rules run (Laravel's `parseData`, `Validator.php`
  /// 12.x :366-385) and put back in what comes out: [validated], the
  /// error keys and the attribute in messages (`replacePlaceholders`,
  /// :393-405). Random per validator, so a client cannot send a key that
  /// reads as one.
  late final String _hash = () {
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < 16; i++) 0x61 + random.nextInt(26),
    ]);
  }();
  late final String _dot = '__dot__$_hash';
  late final String _asterisk = '__asterisk__$_hash';

  String _encodeKey(String key) => key.contains('.') || key.contains('*')
      ? key.replaceAll('.', _dot).replaceAll('*', _asterisk)
      : key;

  String _decodeKey(String key) => key.contains(_hash)
      ? key.replaceAll(_dot, '.').replaceAll(_asterisk, '*')
      : key;

  /// [value] with every map key encoded ([_encodeKey]); what has no such
  /// key is returned as it is, not copied.
  Object? _encode(Object? value) => _rekey(value, _encodeKey);

  /// [value] with every map key decoded ([_decodeKey]).
  Object? _decode(Object? value) => _rekey(value, _decodeKey);

  static Object? _rekey(Object? value, String Function(String) key) {
    switch (value) {
      case final Map<Object?, Object?> map:
        var changed = false;
        final copy = <String, Object?>{};
        for (final MapEntry(key: k, value: v) in map.entries) {
          final name = k is String ? key(k) : '$k';
          final child = _rekey(v, key);
          changed |= !identical(name, k) || !identical(child, v);
          copy[name] = child;
        }
        return changed ? copy : map;
      case final List<Object?> list:
        List<Object?>? copy;
        for (var i = 0; i < list.length; i++) {
          final child = _rekey(list[i], key);
          if (!identical(child, list[i])) {
            (copy ??= List.of(list))[i] = child;
          }
        }
        return copy ?? list;
      default:
        return value;
    }
  }

  /// Errors from the last [run] (empty when valid).
  Map<String, List<String>> get errors => Map.unmodifiable(_errors ?? const {});

  final Map<String, List<String>> _failed = {};

  /// The rules that failed in the last [run], by attribute: rule names
  /// only, never the input. Laravel's `$validator->failed()` keys each
  /// failure by its rule class name with its parameters
  /// (`['email' => ['Required' => []]]`); this lists the rule names as
  /// written (`{'email': ['required']}`). An error added with [addError]
  /// has no rule and is not listed.
  Map<String, List<String>> failed() => {
    for (final entry in _failed.entries) entry.key: List.of(entry.value),
  };

  /// Runs validation and returns the errors (empty when valid).
  Future<Map<String, List<String>>> run() async {
    _errors = {};
    _failed.clear();
    _excluded.clear();
    _nestedPatterns.clear();
    _input = _encode(data)! as Map<String, Object?>;
    // Laravel's filterConditionalRules: `when`/`unless` are decided once,
    // on the whole input, before any rule runs.
    final resolved = {
      for (final MapEntry(:key, :value) in rules.entries)
        key: _resolveConditionals(value, key),
    };
    // Laravel's explodeWildcardRules: every `forEach` is compiled before
    // any rule runs, so a dependent rule (`required_if:flag,true`) sees a
    // `boolean` rule whichever `when` or `forEach` gave it.
    final plan = <_Planned>[];
    for (final MapEntry(key: pattern, value: list) in resolved.entries) {
      for (final attribute in expandPattern(_input, pattern).toList()) {
        _plan(attribute, pattern, list, plan);
      }
    }
    _booleans = {
      for (final (:attribute, :pattern, :rules) in plan)
        if (rules.any((rule) => rule is BooleanRule)) ...[attribute, pattern],
    };
    for (final (:attribute, :pattern, :rules) in plan) {
      if (_isExcluded(attribute)) {
        continue;
      }
      await _validateAttribute(attribute, pattern, rules);
      if (stopOnFirstFailure && _errors!.isNotEmpty) {
        break;
      }
    }
    for (final hook in _after) {
      await hook(this);
    }
    return errors;
  }

  /// Whether every rule passes.
  Future<bool> passes() async => (await run()).isEmpty;

  /// Whether any rule fails.
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

  /// The subset of [data] covered by rules, keeping nested structure: each
  /// level has the shape it has in [data] (a map stays a map, its keys as
  /// sent; a list stays a list), so a key the client sent never decides
  /// the length of a list.
  ValidatedData validated() {
    final result = <String, Object?>{};
    for (final pattern in [...rules.keys, ..._nestedPatterns]) {
      for (final attribute in expandPattern(_input, pattern)) {
        if (_isExcluded(attribute) ||
            !ValidationContext.exists(_input, attribute)) {
          continue;
        }
        _assign(result, _input, attribute.split('.'));
      }
    }
    return ValidatedData(result);
  }

  /// [data] without the excluded attributes, as Laravel's `removeAttribute`:
  /// a later rule sees them as missing. [data] itself stays as given.
  late Map<String, Object?> _input = _encode(data)! as Map<String, Object?>;

  // ValidationContext.memo, one per run: keyed by the errors map, which
  // each run makes anew.
  final Expando<Map<Object, Object?>> _memos = Expando();
  final Set<String> _excluded = <String>{};

  /// The attributes `forEachNested` gave rules in the last [run]
  /// (`items.2.meta`); [validated] includes them, as Laravel merges
  /// compiled rules into the validator's rules.
  final Set<String> _nestedPatterns = <String>{};

  /// How deep `when`, `unless` and `forEach` may nest in one another. Laravel
  /// sets no limit; one here turns a `forEach` callback that returns itself
  /// into an error naming the attribute instead of an endless loop. The
  /// nesting comes from the application's rules, never from the input.
  static const int maxRuleNesting = 8;

  void _checkNesting(int depth, String pattern) {
    if (depth >= maxRuleNesting) {
      throw StateError(
        'The rules of [$pattern] nest when/unless/forEach more than '
        '$maxRuleNesting levels deep; a forEach callback that returns '
        'forEach again does this.',
      );
    }
  }

  List<Rule> _resolveConditionals(
    List<Rule> list,
    String pattern, [
    int depth = 0,
  ]) {
    if (!list.any((rule) => rule is ConditionalRule)) {
      return list;
    }
    _checkNesting(depth, pattern);
    return [
      for (final rule in list)
        if (rule is ConditionalRule)
          ..._resolveConditionals(rule.choose(data), pattern, depth + 1)
        else
          rule,
    ];
  }

  /// Adds [list] on [attribute] to [plan], with each `forEach` compiled for
  /// its value first (Laravel's explodeWildcardRules): the rules it gives
  /// the element run with the others, then the rules it gives the
  /// element's keys, in the order Laravel merges them.
  void _plan(
    String attribute,
    String pattern,
    List<Rule> list,
    List<_Planned> plan, [
    int depth = 0,
  ]) {
    if (!list.any((rule) => rule is ForEachRule)) {
      plan.add((attribute: attribute, pattern: pattern, rules: list));
      return;
    }
    _checkNesting(depth, pattern);
    final dot = attribute.lastIndexOf('.');
    // The callback sees the data as sent: keys with a `.` or `*` decoded.
    final ForEachItem item = (
      value: _decode(ValidationContext.dig(_input, attribute)),
      attribute: _decodeKey(attribute),
      parent: dot == -1
          ? null
          : _decode(ValidationContext.dig(_input, attribute.substring(0, dot))),
      input: data,
    );
    final own = <Rule>[];
    final nested = <String, List<Rule>>{};
    for (final rule in list) {
      if (rule is! ForEachRule) {
        own.add(rule);
        continue;
      }
      final compiled = rule.compile(item);
      own.addAll(_resolveConditionals(compiled.own, pattern, depth + 1));
      for (final MapEntry(:key, :value) in compiled.nested.entries) {
        (nested[key] ??= []).addAll(
          _resolveConditionals(value, '$pattern.$key', depth + 1),
        );
      }
    }
    _plan(attribute, pattern, own, plan, depth + 1);
    for (final MapEntry(:key, value: rules) in nested.entries) {
      final keyPattern = '$attribute.$key';
      _nestedPatterns.add(keyPattern);
      for (final concrete in expandPattern(_input, keyPattern).toList()) {
        _plan(concrete, '$pattern.$key', rules, plan, depth + 1);
      }
    }
  }

  bool _isExcluded(String attribute) =>
      _excluded.any((e) => attribute == e || attribute.startsWith('$e.'));

  void _exclude(String attribute) {
    _excluded.add(attribute);
    _input = _without(_input, attribute.split('.')) as Map<String, Object?>;
  }

  /// Copies the path, so nothing the caller holds changes. An element of a
  /// list stays, or the indexes after it would shift.
  static Object? _without(Object? source, List<String> path) {
    final key = path.first;
    if (source is Map<String, Object?> && source.containsKey(key)) {
      final copy = {...source};
      if (path.length == 1) {
        copy.remove(key);
      } else {
        copy[key] = _without(source[key], path.sublist(1));
      }
      return copy;
    }
    final index = int.tryParse(key);
    if (source is List<Object?> &&
        path.length > 1 &&
        index != null &&
        index >= 0 &&
        index < source.length) {
      return [...source]..[index] = _without(source[index], path.sublist(1));
    }
    return source;
  }

  Future<void> _validateAttribute(
    String attribute,
    String pattern,
    List<Rule> ruleList,
  ) async {
    final present = ValidationContext.exists(_input, attribute);
    // Every rule sees the value as sent (Laravel decodes it for custom
    // rules, `validateUsingCustomRule`, Validator.php 12.x :926): a rule
    // that compares keys (`required_array_keys`, `array:a,b`) compares the
    // keys the client sent with the ones written in the rule.
    final value = present
        ? _decode(ValidationContext.dig(_input, attribute))
        : null;
    final nullable = ruleList.any((r) => r is NullableRule);
    final sometimes = ruleList.any((r) => r is SometimesRule);
    final bail = ruleList.any((r) => r is BailRule);
    // Laravel's hasRule($attribute, $this->numericRules): size rules then
    // measure a string by its numeric value.
    final numeric = ruleList.any((r) => r is NumericRule || r is IntegerRule);

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
      // Laravel's hasNotFailedPreviousRuleIfPresenceRule: no query for an
      // attribute that already failed another rule.
      if ((rule.name == 'unique' || rule.name == 'exists') &&
          (_errors?[_decodeKey(attribute)]?.isNotEmpty ?? false)) {
        continue;
      }
      final context = ValidationContext(
        // A closure sees the attribute as sent (Laravel's
        // `$originalAttribute` for custom rules, :917); the rules of the
        // framework keep the form they look the data up with.
        attribute: rule is ClosureRule ? _decodeKey(attribute) : attribute,
        pattern: pattern,
        value: value,
        present: present,
        data: _input,
        container: container,
        locale: locale,
        numeric: numeric,
        booleans: _booleans,
        attributeNames: attributes,
        memo: _memos[_errors!] ??= {},
      );
      final failure = await rule.passes(context);
      if (failure != null && ExcludeRule.names.contains(rule.name)) {
        _exclude(attribute);
        return;
      }
      if (failure != null) {
        addError(attribute, _message(failure, context, rule));
        _failed.putIfAbsent(_decodeKey(attribute), () => []).add(rule.name);
        // Laravel's shouldStopValidating: `bail` stops at any failure; a
        // failed rule of Laravel's $implicitRules stops too, since the other
        // rules would only describe the empty field again ("must be a
        // string" after "is required").
        if (bail || laravelImplicitRules.contains(rule.name)) {
          return;
        }
      }
    }
  }

  String _message(String key, ValidationContext context, Rule rule) {
    final ValidationContext(attribute: encoded, :pattern) = context;
    final attribute = _decodeKey(encoded);
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
      parameters: rule.parametersFor(context),
      overrides: overrides,
    );
  }

  /// Puts the value at [path] of [input] into [target], building each level
  /// as it is in [input]: where [input] has a map, [target] gets a map (the
  /// key decoded, as sent); where it has a list, a list, at an index that
  /// exists in it (the gaps of what was not validated are `null`, as
  /// before). Nothing here reads a key as a number: a list is never longer
  /// than the list it comes from.
  void _assign(
    Map<String, Object?> target,
    Map<String, Object?> input,
    List<String> path,
  ) {
    Object current = target;
    Object? source = input;
    for (var i = 0; i < path.length; i++) {
      final segment = path[i];
      final last = i == path.length - 1;
      final Object? child;
      final int? index;
      switch (source) {
        case final Map<Object?, Object?> map:
          child = map[segment];
          index = null;
        case final List<Object?> list:
          final at = _listIndex(segment, list.length);
          if (at == null) {
            return;
          }
          child = list[at];
          index = at;
        default:
          return;
      }
      Object? put(Object? existing) => last
          ? _decode(child)
          : existing ??
                (child is List<Object?> ? <Object?>[] : <String, Object?>{});
      switch (current) {
        case final Map<String, Object?> map when index == null:
          final key = _decodeKey(segment);
          final next = map[key] = put(map[key]);
          if (last || next == null) {
            return;
          }
          current = next;
        case final List<Object?> list when index != null:
          while (list.length <= index) {
            list.add(null);
          }
          final next = list[index] = put(list[index]);
          if (last || next == null) {
            return;
          }
          current = next;
        default:
          return;
      }
      source = child;
    }
  }

  /// [segment] as an index of a list of [length]: only the canonical form
  /// of an index that exists (`'1'`, not `'01'` or `'-1'`), else null.
  static int? _listIndex(String segment, int length) {
    final index = int.tryParse(segment);
    return index != null && index >= 0 && index < length && '$index' == segment
        ? index
        : null;
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

/// Laravel's `Validator::$implicitRules` (laravel/framework 8 to 13, the
/// same list), by rule name: a failure of one of these ends the
/// validation of its attribute. `prohibited` is not one of them.
const Set<String> laravelImplicitRules = {
  'accepted',
  'accepted_if',
  'declined',
  'declined_if',
  'filled',
  'missing',
  'missing_if',
  'missing_unless',
  'missing_with',
  'missing_with_all',
  'present',
  'present_if',
  'present_unless',
  'present_with',
  'present_with_all',
  'required',
  'required_if',
  'required_if_accepted',
  'required_if_declined',
  'required_unless',
  'required_with',
  'required_with_all',
  'required_without',
  'required_without_all',
};
