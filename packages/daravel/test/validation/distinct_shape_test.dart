import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `distinct` compares what its pattern matches whatever shape holds it, as
/// Laravel does: `extractDistinctValues` takes `Arr::dot` of the data and
/// every key matching the attribute's pattern, a `*` being `[^.]+`
/// (`laravel/framework` 12.x
/// `src/Illuminate/Validation/Concerns/ValidatesAttributes.php` :919-930).
/// A JSON object and a sparse form (`items[1]`, `items[3]`) hold their
/// items in a map, not a list.
void main() {
  Future<Set<String>> failing(
    Map<String, Object?> data,
    String pattern,
  ) async => (await Validator(data, {pattern: 'distinct'}).run()).keys.toSet();

  final cases = <(String, String, Map<String, Object?>, Set<String>)>[
    (
      'a JSON list',
      'items.*.id',
      {
        'items': [
          {'id': 1},
          {'id': 1},
        ],
      },
      {'items.0.id', 'items.1.id'},
    ),
    (
      'a JSON object of free keys',
      'items.*.id',
      {
        'items': {
          'a': {'id': 1},
          'b': {'id': 1},
        },
      },
      {'items.a.id', 'items.b.id'},
    ),
    (
      'a sparse form (1, 3)',
      'items.*.id',
      {
        'items': {
          '1': {'id': '1'},
          '3': {'id': '1'},
        },
      },
      {'items.1.id', 'items.3.id'},
    ),
    (
      'an ordered map (0, 1)',
      'items.*.id',
      {
        'items': {
          '0': {'id': '1'},
          '1': {'id': '1'},
        },
      },
      {'items.0.id', 'items.1.id'},
    ),
    (
      'scalars in a map',
      'items.*',
      {
        'items': {'a': 1, 'b': 1},
      },
      {'items.a', 'items.b'},
    ),
    (
      'two levels: every item of every parent is compared',
      'a.*.items.*.id',
      {
        'a': [
          {
            'items': [
              {'id': 1},
            ],
          },
          {
            'items': [
              {'id': 1},
            ],
          },
        ],
      },
      {'a.0.items.0.id', 'a.1.items.0.id'},
    ),
    (
      'a fixed level before the wildcard',
      'a.b.*',
      {
        'a': {
          'b': [1, 1],
        },
      },
      {'a.b.0', 'a.b.1'},
    ),
    (
      'a top-level wildcard',
      '*.id',
      {
        'x': {'id': 1},
        'y': {'id': 1},
      },
      {'x.id', 'y.id'},
    ),
    (
      'an empty key: its value is compared with the others, theirs not '
          'with it ([^.]+ never matches an empty key)',
      'items.*.id',
      {
        'items': {
          '': {'id': 1},
          'x': {'id': 1},
        },
      },
      {'items..id'},
    ),
  ];

  for (final (name, pattern, data, expected) in cases) {
    test('$name ($pattern)', () async {
      expect(await failing(data, pattern), expected);
    });
  }

  group('through HTTP', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) => router.post(
              '/ids',
              (request) async =>
                  (await request.validate({'items.*.id': 'distinct'})).toMap(),
            ),
          )
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    Future<(int, Object?)> send(Request request) async {
      final response = await app.handle(request);
      return (response.status, jsonDecode(await response.bodyText()));
    }

    test('a sparse form is a 422', () async {
      final (status, body) = await send(
        Request.fake(
          method: 'POST',
          path: '/ids',
          form: {'items[1][id]': '7', 'items[3][id]': '7'},
          headers: {'accept': 'application/json'},
        ),
      );
      expect(status, 422);
      expect(((body! as Map)['errors'] as Map).keys.toSet(), {
        'items.1.id',
        'items.3.id',
      });
    });

    test('a JSON object is a 422', () async {
      final (status, _) = await send(
        Request.fake(
          method: 'POST',
          path: '/ids',
          json: {
            'items': {
              'a': {'id': 7},
              'b': {'id': 7},
            },
          },
          headers: {'accept': 'application/json'},
        ),
      );
      expect(status, 422);
    });
  });
}
