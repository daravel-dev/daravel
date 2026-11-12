import 'dart:async';

import '../foundation/container.dart';

/// Everything a [Rule] needs to evaluate one attribute (BLUEPRINT_V2 §7.4.1).
final class ValidationContext {
  /// The context of [attribute] (the concrete path, such as `items.2.id`),
  /// matched by the rule key [pattern], whose [value] was [present] in
  /// [data].
  const ValidationContext({
    required this.attribute,
    required this.pattern,
    required this.value,
    required this.present,
    required this.data,
    this.container,
    this.locale = 'en',
    this.numeric = false,
    this.booleans = const <String>{},
    this.attributeNames = const <String, String>{},
    this.memo,
  });

  /// The attributes with a `boolean` rule (Laravel's
  /// `shouldConvertToBoolean`).
  final Set<String> booleans;

  /// The custom attribute names of this validation.
  final Map<String, String> attributeNames;

  /// [attribute] as a message shows it, with its `*` replaced as [resolve]
  /// does (a custom name given for the resolved path wins, then one for the
  /// path as written).
  String displayName(String attribute) {
    final resolved = resolve(attribute);
    return attributeNames[resolved] ??
        attributeNames[attribute] ??
        resolved.replaceAll('_', ' ');
  }

  /// [path] with each `*` replaced by the key the current [attribute] has
  /// at the matching `*` of its [pattern], in order: `items.*.b` is
  /// `items.2.b` while validating `items.2.a` of `items.*.a` (Laravel's
  /// `getExplicitKeys` and `replaceAsterisksInParameters`, which the
  /// dependent rules' other fields go through). Without a `*`, or when the
  /// pattern has none, [path] is returned as is.
  String resolve(String path) {
    if (!path.contains('*') || !pattern.contains('*')) {
      return path;
    }
    final keys = <String>[];
    final patternParts = pattern.split('.');
    final attributeParts = attribute.split('.');
    for (var i = 0; i < patternParts.length && i < attributeParts.length; i++) {
      if (patternParts[i] == '*') {
        keys.add(attributeParts[i]);
      }
    }
    var next = 0;
    return path.replaceAllMapped(
      '*',
      (m) => next < keys.length ? keys[next++] : '*',
    );
  }

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

  /// Values a rule computes once per validation run and reuses for every
  /// attribute (`distinct` counts a list once, not once per item). A fresh
  /// map for each `Validator.run`; null for a context built elsewhere, where
  /// a rule computes as before. Keys hold [data] itself, so the input an
  /// excluded attribute leaves behind (a new map) gets entries of its own.
  final Map<Object, Object?>? memo;

  /// Locale used for messages.
  final String locale;

  /// Looks up another attribute by dot path from the root; a `*` in [path]
  /// is [resolve]d first.
  Object? root(String path) => dig(data, resolve(path));

  /// Whether another attribute's key exists, by dot path from the root
  /// (Laravel's `Arr::has`); a `*` in [path] is [resolve]d first.
  bool has(String path) => exists(data, resolve(path));

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
  /// Rules are usually const.
  const Rule();

  /// Rule identifier used in messages and the string DSL (`required`).
  String get name;

  /// Implicit rules run even when the attribute is absent or empty
  /// (`required*`, `present`, `prohibited*`).
  bool get implicit => false;

  /// Placeholder values for messages (`:min`, `:other`, `:values`).
  Map<String, Object?> get parameters => const <String, Object?>{};

  /// [parameters] for a failure on [context], for a placeholder that shows
  /// the input (`accepted_if`'s `:value`).
  Map<String, Object?> parametersFor(ValidationContext context) => parameters;

  /// Hint for OpenAPI generation (`{'type': 'string', 'maxLength': 32}`).
  Map<String, Object?> get schemaHint => const <String, Object?>{};

  /// Checks the value in [context]: the message key or text when it fails,
  /// null when it passes.
  FutureOr<String?> passes(ValidationContext context);
}

/// Marker: `null` values skip the remaining rules.
final class NullableRule extends Rule {
  /// The nullable marker; use [Rules.nullable].
  const NullableRule();
  @override
  String get name => 'nullable';
  @override
  String? passes(ValidationContext context) => null;
}

/// Marker: validate only when the attribute is present.
final class SometimesRule extends Rule {
  /// The sometimes marker; use [Rules.sometimes].
  const SometimesRule();
  @override
  String get name => 'sometimes';
  @override
  String? passes(ValidationContext context) => null;
}

/// Marker: stop validating the attribute after the first failure.
final class BailRule extends Rule {
  /// The bail marker; use [Rules.bail].
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
