/// Laravel's `Illuminate\JsonSchema`: a typed builder for JSON Schema documents.
///
/// ```dart
/// final schema = JsonSchema.object({
///   'name': JsonSchema.string().required().max(255),
///   'age': JsonSchema.integer().min(0).nullable(),
///   'tags': JsonSchema.array().items(JsonSchema.string()),
/// }).withoutAdditionalProperties();
///
/// schema.toArray();
/// ```
abstract final class JsonSchema {
  /// An object with the given properties.
  static ObjectSchema object([
    Map<String, SchemaType> properties = const <String, SchemaType>{},
  ]) => ObjectSchema(properties);

  /// An array.
  static ArraySchema array() => ArraySchema();

  /// A string.
  static StringSchema string() => StringSchema();

  /// An integer.
  static IntegerSchema integer() => IntegerSchema();

  /// A number.
  static NumberSchema number() => NumberSchema();

  /// A boolean.
  static BooleanSchema boolean() => BooleanSchema();

  /// A value of any of the named [types] (`"type": ["string", "integer"]`).
  static UnionSchema union(List<String> types) => UnionSchema(types);

  /// A value matching any of [schemas].
  static AnyOfSchema anyOf(List<SchemaType> schemas) => AnyOfSchema(schemas);
}

/// One node of a schema. Named so because `Type` is `dart:core`'s.
abstract class SchemaType {
  bool _required = false;
  bool _nullable = false;
  String? _title;
  String? _description;
  Object? _default;
  List<Object?>? _enum;

  /// The `type` keyword.
  Object? get _type;

  /// The keywords of this kind of node.
  Map<String, Object?> get _keywords => const <String, Object?>{};

  /// The schema as a JSON Schema map.
  Map<String, Object?> toArray() {
    final type = _type;
    return <String, Object?>{
      'type': !_nullable
          ? type
          : type is List<Object?>
          ? [...type, 'null']
          : [type, 'null'],
      ..._common,
      ..._keywords,
    };
  }

  Map<String, Object?> get _common => <String, Object?>{
    'title': ?_title,
    'description': ?_description,
    'default': ?_default,
    'enum': ?_enum,
  };

  /// The schema as JSON.
  Map<String, Object?> toJson() => toArray();
}

/// The setters every node shares. An extension, so each returns its own type.
extension SchemaTypeFluent<S extends SchemaType> on S {
  /// Marks the property as required in its object.
  S required([bool required = true]) {
    _required = required;
    return this;
  }

  /// Allows `null` too.
  S nullable([bool nullable = true]) {
    _nullable = nullable;
    return this;
  }

  /// The schema's title.
  S title(String value) {
    _title = value;
    return this;
  }

  /// The schema's description.
  S description(String value) {
    _description = value;
    return this;
  }

  /// The `default` keyword; `default` is reserved in Dart.
  S defaultTo(Object? value) {
    _default = value;
    return this;
  }

  /// The `enum` keyword; `enum` is reserved in Dart.
  S enumValues(Iterable<Object?> values) {
    _enum = values.toList();
    return this;
  }
}

/// A JSON object schema.
final class ObjectSchema extends SchemaType {
  /// An object with [properties].
  ObjectSchema(this.properties);

  /// The object's properties.
  final Map<String, SchemaType> properties;
  bool _closed = false;

  /// Refuses properties not listed (`additionalProperties: false`).
  ObjectSchema withoutAdditionalProperties() {
    _closed = true;
    return this;
  }

  @override
  Object? get _type => 'object';

  @override
  Map<String, Object?> get _keywords {
    final required = [
      for (final entry in properties.entries)
        if (entry.value._required) entry.key,
    ];
    return <String, Object?>{
      if (_closed) 'additionalProperties': false,
      if (properties.isNotEmpty)
        'properties': <String, Object?>{
          for (final entry in properties.entries)
            entry.key: entry.value.toArray(),
        },
      if (required.isNotEmpty) 'required': required,
    };
  }
}

/// A JSON array schema.
final class ArraySchema extends SchemaType {
  int? _min;
  int? _max;
  SchemaType? _items;
  bool _unique = false;

  /// At least [value] items.
  ArraySchema min(int value) {
    _min = value;
    return this;
  }

  /// At most [value] items.
  ArraySchema max(int value) {
    _max = value;
    return this;
  }

  /// Items of [type].
  ArraySchema items(SchemaType type) {
    _items = type;
    return this;
  }

  /// Items all different.
  ArraySchema unique([bool unique = true]) {
    _unique = unique;
    return this;
  }

  @override
  Object? get _type => 'array';

  @override
  Map<String, Object?> get _keywords => <String, Object?>{
    'minItems': ?_min,
    'maxItems': ?_max,
    if (_items case final SchemaType items) 'items': items.toArray(),
    if (_unique) 'uniqueItems': true,
  };
}

/// A JSON string schema.
final class StringSchema extends SchemaType {
  int? _min;
  int? _max;
  String? _pattern;
  String? _format;

  /// At least [value] characters.
  StringSchema min(int value) {
    _min = value;
    return this;
  }

  /// At most [value] characters.
  StringSchema max(int value) {
    _max = value;
    return this;
  }

  /// Matching the regular expression [value].
  StringSchema pattern(String value) {
    _pattern = value;
    return this;
  }

  /// Of the format [value] (`email`, `date-time`, `uuid`...).
  StringSchema format(String value) {
    _format = value;
    return this;
  }

  @override
  Object? get _type => 'string';

  @override
  Map<String, Object?> get _keywords => <String, Object?>{
    'minLength': ?_min,
    'maxLength': ?_max,
    'pattern': ?_pattern,
    'format': ?_format,
  };
}

/// A JSON integer schema.
final class IntegerSchema extends SchemaType {
  int? _min;
  int? _max;
  int? _multipleOf;

  /// At least [value].
  IntegerSchema min(int value) {
    _min = value;
    return this;
  }

  /// At most [value].
  IntegerSchema max(int value) {
    _max = value;
    return this;
  }

  /// A multiple of [value].
  IntegerSchema multipleOf(int value) {
    _multipleOf = value;
    return this;
  }

  @override
  Object? get _type => 'integer';

  @override
  Map<String, Object?> get _keywords => <String, Object?>{
    'minimum': ?_min,
    'maximum': ?_max,
    'multipleOf': ?_multipleOf,
  };
}

/// A JSON number schema.
final class NumberSchema extends SchemaType {
  num? _min;
  num? _max;
  num? _multipleOf;

  /// At least [value].
  NumberSchema min(num value) {
    _min = value;
    return this;
  }

  /// At most [value].
  NumberSchema max(num value) {
    _max = value;
    return this;
  }

  /// A multiple of [value].
  NumberSchema multipleOf(num value) {
    _multipleOf = value;
    return this;
  }

  @override
  Object? get _type => 'number';

  @override
  Map<String, Object?> get _keywords => <String, Object?>{
    'minimum': ?_min,
    'maximum': ?_max,
    'multipleOf': ?_multipleOf,
  };
}

/// A JSON boolean schema.
final class BooleanSchema extends SchemaType {
  @override
  Object? get _type => 'boolean';
}

/// A value of any of several JSON types.
final class UnionSchema extends SchemaType {
  /// Any of the JSON [types].
  UnionSchema(this.types);

  /// The JSON type names.
  final List<String> types;

  @override
  Object? get _type => types;
}

/// A value matching any of several schemas.
final class AnyOfSchema extends SchemaType {
  /// Any of [schemas].
  AnyOfSchema(this.schemas);

  /// The schemas.
  final List<SchemaType> schemas;

  @override
  Object? get _type => null;

  @override
  Map<String, Object?> toArray() => <String, Object?>{
    'anyOf': [
      for (final schema in schemas) schema.toArray(),
      if (_nullable) const <String, Object?>{'type': 'null'},
    ],
    ..._common,
  };
}
