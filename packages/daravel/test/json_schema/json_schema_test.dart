import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('an object lists its required properties', () {
    final schema = JsonSchema.object({
      'name': JsonSchema.string().required().min(1).max(255),
      'age': JsonSchema.integer().min(0).max(150).nullable(),
      'tags': JsonSchema.array()
          .items(JsonSchema.string())
          .min(1)
          .max(5)
          .unique(),
    }).withoutAdditionalProperties();
    expect(schema.toArray(), {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'name': {'type': 'string', 'minLength': 1, 'maxLength': 255},
        'age': {
          'type': ['integer', 'null'],
          'minimum': 0,
          'maximum': 150,
        },
        'tags': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 5,
          'items': {'type': 'string'},
          'uniqueItems': true,
        },
      },
      'required': ['name'],
    });
  });

  test('an empty object has no properties key', () {
    expect(JsonSchema.object().toArray(), {'type': 'object'});
  });

  test('common keywords', () {
    expect(
      JsonSchema.string()
          .title('Status')
          .description('The state')
          .defaultTo('open')
          .enumValues(['open', 'closed'])
          .pattern('^[a-z]+')
          .format('slug')
          .toArray(),
      {
        'type': 'string',
        'title': 'Status',
        'description': 'The state',
        'default': 'open',
        'enum': ['open', 'closed'],
        'pattern': '^[a-z]+',
        'format': 'slug',
      },
    );
  });

  test('number and boolean', () {
    expect(JsonSchema.number().min(0.5).multipleOf(0.5).toArray(), {
      'type': 'number',
      'minimum': 0.5,
      'multipleOf': 0.5,
    });
    expect(JsonSchema.boolean().defaultTo(false).toArray(), {
      'type': 'boolean',
      'default': false,
    });
  });

  test('union, and nullable adds null to it', () {
    expect(JsonSchema.union(['string', 'integer']).nullable().toArray(), {
      'type': ['string', 'integer', 'null'],
    });
  });

  test('anyOf has no type, and nullable adds a branch', () {
    expect(
      JsonSchema.anyOf([JsonSchema.string(), JsonSchema.integer()])
          .nullable()
          .description('Either')
          .toArray(),
      {
        'anyOf': [
          {'type': 'string'},
          {'type': 'integer'},
          {'type': 'null'},
        ],
        'description': 'Either',
      },
    );
  });

  test('it encodes to JSON', () {
    expect(
      jsonDecode(jsonEncode(JsonSchema.object({'a': JsonSchema.boolean()}))),
      {
        'type': 'object',
        'properties': {
          'a': {'type': 'boolean'},
        },
      },
    );
  });
}
