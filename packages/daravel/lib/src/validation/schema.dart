import 'rule.dart';
import 'rule_parser.dart';
import 'rules.dart';

/// Converts validation rules (the map given to `request.validate` or a
/// `FormRequest`) into a JSON Schema object (OpenAPI 3.1 dialect), so API
/// documents and generated clients describe exactly what the server
/// validates:
///
/// ```dart
/// rulesToJsonSchema({
///   'email': 'required|email|max:255',
///   'tags.*': 'string',
///   'address.city': 'nullable|string',
/// });
/// ```
///
/// Dotted keys become nested objects and `*` becomes array `items`.
/// `required` (without `sometimes`) lists the field as required, `nullable`
/// adds `"null"` to its type, `min`/`max`/`between`/`size` map to the length,
/// value or item bounds of the field's type, and `confirmed` adds the
/// `<field>_confirmation` property.
Map<String, Object?> rulesToJsonSchema(Map<String, Object> rules) {
  final root = _Node();
  for (final MapEntry(key: path, value: parsed) in RuleParser.parseMap(
    rules,
  ).entries) {
    var node = root;
    for (final segment in path.split('.')) {
      node = segment == '*'
          ? (node.items ??= _Node())
          : node.children.putIfAbsent(segment, _Node.new);
    }
    node.rules.addAll(parsed);
  }
  return root.toSchema(isRoot: true);
}

const Set<String> _boundKeys = {'minimum', 'maximum', 'minLength', 'maxLength'};

final class _Node {
  final Map<String, _Node> children = <String, _Node>{};
  final List<Rule> rules = <Rule>[];
  _Node? items;

  bool get required =>
      rules.any((r) => r is RequiredRule) &&
      !rules.any((r) => r is SometimesRule);

  bool get confirmed => rules.any((r) => r is ConfirmedRule);

  Map<String, Object?> toSchema({bool isRoot = false}) {
    final schema = <String, Object?>{};
    for (final rule in rules) {
      // Size rules hint every bound; the type decides which one applies.
      final sized =
          rule is MinRule ||
          rule is MaxRule ||
          rule is BetweenRule ||
          rule is SizeRule;
      for (final MapEntry(:key, :value) in rule.schemaHint.entries) {
        if (key == 'required' || (sized && _boundKeys.contains(key))) {
          continue; // Handled below, depending on the type.
        }
        schema[key] = value;
      }
    }
    if (children.isNotEmpty || isRoot) {
      schema['type'] = 'object';
      final properties = <String, Object?>{};
      final required = <String>[];
      for (final MapEntry(key: name, value: child) in children.entries) {
        properties[name] = child.toSchema();
        if (child.required) {
          required.add(name);
        }
        if (child.confirmed) {
          final confirmation = '${name}_confirmation';
          properties[confirmation] = <String, Object?>{
            if (child.typeName != null) 'type': child.typeName,
            'description': 'Must match `$name`.',
          };
          if (child.required) {
            required.add(confirmation);
          }
        }
      }
      schema['properties'] = properties;
      if (required.isNotEmpty) {
        schema['required'] = required;
      }
    }
    final itemNode = items;
    if (itemNode != null) {
      schema['type'] = 'array';
      schema['items'] = itemNode.toSchema();
    }
    _applyBounds(schema);
    if (rules.any((r) => r is NullableRule)) {
      final type = schema['type'];
      if (type is String) {
        schema['type'] = [type, 'null'];
      } else if (type == null) {
        schema['nullable'] = true;
      }
    }
    return schema;
  }

  /// The schema type implied by the rules alone (before bounds/nullable).
  String? get typeName {
    for (final rule in rules) {
      final type = rule.schemaHint['type'];
      if (type is String) {
        return type;
      }
    }
    return items != null ? 'array' : (children.isNotEmpty ? 'object' : null);
  }

  void _applyBounds(Map<String, Object?> schema) {
    final type = schema['type'];
    final (minKey, maxKey) = switch (type) {
      'string' => ('minLength', 'maxLength'),
      'array' => ('minItems', 'maxItems'),
      'integer' || 'number' => ('minimum', 'maximum'),
      _ => (null, null),
    };
    if (minKey == null || maxKey == null) {
      return; // Laravel's size rules depend on the type; unknown here.
    }
    for (final rule in rules) {
      switch (rule) {
        case MinRule(:final min):
          schema[minKey] = min;
        case MaxRule(:final max):
          schema[maxKey] = max;
        case BetweenRule(:final min, :final max):
          schema[minKey] = min;
          schema[maxKey] = max;
        case SizeRule(:final size):
          schema[minKey] = size;
          schema[maxKey] = size;
        default:
          break;
      }
    }
  }
}
