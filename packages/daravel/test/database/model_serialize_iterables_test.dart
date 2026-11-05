import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Tag extends Model {
  static final ModelDefinition<Tag> definition = ModelDefinition<Tag>(
    table: 'tags',
    factory: Tag.new,
    guarded: [],
    hidden: ['secret'],
  );

  @override
  ModelDefinition<Tag> get modelDefinition => Tag.definition;
}

enum Level { low, high }

Tag tag(int id) => Tag()
  ..setAttr('id', id)
  ..setAttr('secret', 's$id');

/// `Model.toJson` serializes models, dates and enums inside any collection,
/// as Laravel's `toArray` does through `Arrayable` collections and arrays:
/// a model nested in a `Set`, an `Iterable` or a `Map` is its `toJson` (its
/// hidden attributes stay hidden), never the object itself.
void main() {
  final at = DateTime.utc(2026, 11, 4, 12, 30);

  Map<String, Object?> json(Object? relation) {
    final owner = Tag()
      ..setAttr('id', 1)
      ..setRelation('items', relation);
    // Round-trips through jsonEncode: a model left as an object would throw.
    return jsonDecode(jsonEncode(owner.toJson())) as Map<String, Object?>;
  }

  test('a Set<Model> relation', () {
    expect(json({tag(2), tag(3)})['items'], [
      {'id': 2},
      {'id': 3},
    ]);
  });

  test('an Iterable<Model> that is not a List', () {
    expect(json([2, 3].map(tag))['items'], [
      {'id': 2},
      {'id': 3},
    ]);
  });

  test('a List<dynamic> mixing models, dates, enums and scalars', () {
    expect(json(<dynamic>[tag(2), at, Level.high, 4, 'x', null])['items'], [
      {'id': 2},
      jsonDate(at),
      'high',
      4,
      'x',
      null,
    ]);
  });

  test('a nested Map with models and dates, at any depth', () {
    expect(
      json({
        'tag': tag(2),
        'when': at,
        'more': {
          'tags': {tag(3)},
          'list': [
            {'tag': tag(4)},
          ],
        },
      })['items'],
      {
        'tag': {'id': 2},
        'when': jsonDate(at),
        'more': {
          'tags': [
            {'id': 3},
          ],
          'list': [
            {
              'tag': {'id': 4},
            },
          ],
        },
      },
    );
  });

  test('an attribute holding a collection is serialized the same way', () {
    final owner = Tag()
      ..setAttr('id', 1)
      ..setAttr('meta', {
        'at': at,
        'levels': {Level.low},
      });
    expect(jsonDecode(jsonEncode(owner.toJson())), {
      'id': 1,
      'meta': {
        'at': jsonDate(at),
        'levels': ['low'],
      },
    });
  });

  test('a ModelCollection and a List<Model> are unchanged', () {
    expect(json([tag(2)])['items'], [
      {'id': 2},
    ]);
    expect(json(ModelCollection<Tag>([tag(3)]))['items'], [
      {'id': 3},
    ]);
  });

  test('an Iterable with its own toJson keeps it', () {
    expect(json(Page([tag(2)]))['items'], {
      'data': [
        {'id': 2},
      ],
      'total': 1,
    });
  });
}

/// An application collection that is an `Iterable` with a JSON shape of its
/// own (not a list), as a paginator has.
final class Page extends Iterable<Tag> implements JsonSerializable {
  Page(this._items);

  final List<Tag> _items;

  @override
  Iterator<Tag> get iterator => _items.iterator;

  @override
  Map<String, Object?> toJson() => {
    'data': [for (final t in _items) t.toJson()],
    'total': _items.length,
  };
}
