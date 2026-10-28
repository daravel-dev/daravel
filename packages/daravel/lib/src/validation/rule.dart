import 'dart:async';

import '../foundation/container.dart';

/// Everything a [Rule] needs to evaluate one attribute (BLUEPRINT_V2 §7.4.1).
final class ValidationContext {
  const ValidationContext({
    required this.attribute,
    required this.pattern,
    required this.value,
    required this.present,
    required this.data,
    this.container,
    this.locale = 'en',
    this.numeric = false,
  });

  /// Whether the attribute also carries a `numeric` or `integer` rule, so
  /// size rules (`min`, `max`, `between`, `size`) measure a string by its
  /// numeric value, as Laravel does.
  final bool numeric;

  /// Concrete attribute path (`items.2.id`).
  final String attribute;

  /// Rule key as written (`items.*.id`).
  final String pattern;

  /// Current value (`null` when absent).
  final Object? value;

  /// Whether the attribute key exists in the input.
  final bool present;

  /// The complete input.
  final Map<String, Object?> data;

  /// Container for rules that need services (`unique`, `exists`).
  final Container? container;

  /// Locale used for messages.
  final String locale;

  /// Looks up another attribute by dot path from the root.
  Object? root(String path) => dig(data, path);

  /// Looks up a sibling of the current attribute (`items.2.qty` from
  /// `items.2.id` when [key] is `qty`).
  Object? sibling(String key) {
    final dot = attribute.lastIndexOf('.');
    return dig(data, dot == -1 ? key : '${attribute.substring(0, dot)}.$key');
  }

  /// Dot-path lookup supporting list indexes.
  static Object? dig(Object? source, String path) {
    Object? current = source;
    for (final segment in path.split('.')) {
      if (current is Map<Object?, Object?>) {
        if (!current.containsKey(segment)) {
          return null;
        }
        current = current[segment];
      } else if (current is List<Object?>) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          return null;
        }
        current = current[index];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Whether [path] exists in [source] (a `null` value still counts).
  static bool exists(Object? source, String path) {
    Object? current = source;
    for (final segment in path.split('.')) {
      if (current is Map<Object?, Object?>) {
        if (!current.containsKey(segment)) {
          return false;
        }
        current = current[segment];
      } else if (current is List<Object?>) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          return false;
        }
        current = current[index];
      } else {
        return false;
      }
    }
    return true;
  }
}

/// A validation rule. [passes] returns `null` on success or a message
/// reference on failure: either a translation key such as `min.string`
/// (resolved with [parameters]) or a literal message containing a space.
abstract class Rule {
  const Rule();

  /// Rule identifier used in messages and the string DSL (`required`).
  String get name;

  /// Implicit rules run even when the attribute is absent or empty
  /// (`required*`, `present`, `prohibited*`).
  bool get implicit => false;

  /// Placeholder values for messages (`:min`, `:other`, `:values`).
  Map<String, Object?> get parameters => const <String, Object?>{};

  /// Hint for OpenAPI generation (`{'type': 'string', 'maxLength': 32}`).
  Map<String, Object?> get schemaHint => const <String, Object?>{};

  FutureOr<String?> passes(ValidationContext context);
}

/// Marker: `null` values skip the remaining rules.
final class NullableRule extends Rule {
  const NullableRule();
  @override
  String get name => 'nullable';
  @override
  String? passes(ValidationContext context) => null;
}

/// Marker: validate only when the attribute is present.
final class SometimesRule extends Rule {
  const SometimesRule();
  @override
  String get name => 'sometimes';
  @override
  String? passes(ValidationContext context) => null;
}

/// Marker: stop validating the attribute after the first failure.
final class BailRule extends Rule {
  const BailRule();
  @override
  String get name => 'bail';
  @override
  String? passes(ValidationContext context) => null;
}

/// Whether [value] counts as empty for `required` (Laravel semantics).
bool isEmptyValue(Object? value) => switch (value) {
  null => true,
  String() => value.trim().isEmpty,
  List<Object?>() => value.isEmpty,
  Map<Object?, Object?>() => value.isEmpty,
  _ => false,
};
