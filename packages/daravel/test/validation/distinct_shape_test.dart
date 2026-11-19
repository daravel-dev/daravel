import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    // Two wildcards: in this version the items of one parent are compared
    // with each other, not with those of another parent (Laravel compares
    // the whole pattern; 1.28.0 follows it, a change of behavior a patch
    // does not make).
    (
      'two levels: the same value in two parents passes (1.x)',
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
      <String>{},
    ),
    (
      'two levels: the same value twice in one parent fails',
      'a.*.items.*.id',
      {
        'a': [
          {
            'items': [
              {'id': 1},
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
      {'a.0.items.0.id', 'a.0.items.1.id'},
    ),
    (
      'two levels under maps: the same value twice in one parent fails',
      'a.*.items.*.id',
      {
        'a': {
          'p': {
            'items': {
              'x': {'id': 1},
              'y': {'id': 1},
            },
          },
          'q': {
            'items': {
              'x': {'id': 1},
            },
          },
        },
      },
      {'a.p.items.x.id', 'a.p.items.y.id'},
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
    // Duplicates whose every key at a `*` is empty: `[^.]+` matches none
    // of them, so Laravel compares nothing and passes them.
    (
      'duplicates under empty keys only (*.*.*)',
      '*.*.*',
      {
        '': {
          '': ['dup', 'dup'],
        },
      },
      <String>{},
    ),
    (
      'duplicates under an empty key (a.*.*)',
      'a.*.*',
      {
        'a': {
          '': ['dup', 'dup'],
        },
      },
      <String>{},
    ),
    (
      'duplicates under an empty top-level key (*.a.*)',
      '*.a.*',
      {
        '': {
          'a': ['dup', 'dup'],
        },
      },
      <String>{},
    ),
    // The same shapes with named keys: compared.
    (
      'named keys (a.*.*)',
      'a.*.*',
      {
        'a': {
          'k': ['dup', 'dup'],
        },
      },
      {'a.k.0', 'a.k.1'},
    ),
    (
      'named keys (*.a.*)',
      '*.a.*',
      {
        'k': {
          'a': ['dup', 'dup'],
        },
      },
      {'k.a.0', 'k.a.1'},
    ),
  ];

  for (final (name, pattern, data, expected) in cases) {
    test('$name ($pattern)', () async {
      expect(await failing(data, pattern), expected);
    });
  }

  for (final (shape, pattern) in [
    ('a list', 'items.*.id'),
    ('a map', 'items.*.id'),
    ('two levels', 'a.*.items.*.id'),
  ]) {
    test('the work is linear for $shape (1 000 against 4 000 items, counted '
        'reads)', () async {
      final small = await readsFor(1000, shape: shape, pattern: pattern);
      final large = await readsFor(4000, shape: shape, pattern: pattern);
      // Linear is 4; reading the items once per item would be about 16.
      expect(
        large / small,
        inInclusiveRange(1, 4.2),
        reason: '$small → $large',
      );
    });
  }

  test(
    '300 seeded inputs of lists: the same failures as the rule before '
    'this change, for distinct, distinct:strict and distinct:ignore_case',
    () async {
      final random = Random(20261119);
      const values = <Object?>[1, 2, '1', '2', 'a', 'A', null, true, 1.0, ''];
      Object? value() => values[random.nextInt(values.length)];
      var compared = 0;
      var failing = 0;
      for (var i = 0; i < 300; i++) {
        final n = 1 + random.nextInt(5);
        final (Map<String, Object?> data, String pattern) = switch (i % 3) {
          0 => (
            {
              'items': [for (var j = 0; j < n; j++) value()],
            },
            'items.*',
          ),
          1 => (
            {
              'items': [
                for (var j = 0; j < n; j++)
                  random.nextInt(5) == 0
                      ? <String, Object?>{}
                      : <String, Object?>{'id': value()},
              ],
            },
            'items.*.id',
          ),
          _ => (
            {
              'a': [
                for (var j = 0; j < n; j++)
                  {
                    'items': [
                      for (var k = random.nextInt(3); k >= 0; k--)
                        <String, Object?>{'id': value()},
                    ],
                  },
              ],
            },
            'a.*.items.*.id',
          ),
        };
        final expected = <String>{
          for (final attribute in Validator.expandPattern(data, pattern))
            if (ValidationContext.exists(data, attribute) &&
                !_blank(ValidationContext.dig(data, attribute)) &&
                _failedBefore(data, attribute))
              attribute,
        };
        for (final rule in [
          'distinct',
          'distinct:strict',
          'distinct:ignore_case',
        ]) {
          final errors = await Validator(data, {pattern: rule}).run();
          expect(
            errors.keys.toSet(),
            expected,
            reason: '$rule ${jsonEncode(data)}',
          );
          compared++;
        }
        if (expected.isNotEmpty) {
          failing++;
        }
      }
      expect(compared, 900);
      expect(failing, greaterThan(60));
    },
  );

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

/// Reads of a map, counted: the work of a run, which does not vary with the
/// machine as a time does.
final class _CountingMap extends MapBase<String, Object?> {
  _CountingMap(this._source);

  final Map<String, Object?> _source;
  int reads = 0;

  @override
  Object? operator [](Object? key) {
    reads++;
    return _source[key];
  }

  @override
  bool containsKey(Object? key) {
    reads++;
    return _source.containsKey(key);
  }

  @override
  void operator []=(String key, Object? value) => _source[key] = value;

  @override
  void clear() => _source.clear();

  @override
  Iterable<String> get keys => _source.keys;

  @override
  Object? remove(Object? key) => _source.remove(key);
}

/// The reads of every map of the input for [n] items in [shape] (`a list`,
/// `a map`, `two levels`) under [pattern]: linear in [n] when the items
/// are gathered once per run (the memo), not once per item.
Future<int> readsFor(
  int n, {
  String shape = 'a map',
  String pattern = 'items.*.id',
}) async {
  final maps = <_CountingMap>[];
  _CountingMap counted(Map<String, Object?> source) {
    final map = _CountingMap(source);
    maps.add(map);
    return map;
  }

  final Map<String, Object?> data = switch (shape) {
    'a list' => {
      'items': [
        for (var i = 0; i < n; i++) counted({'id': i}),
      ],
    },
    'two levels' => {
      'a': [
        for (var p = 0; p < n ~/ 4; p++)
          counted({
            'items': [
              for (var i = 0; i < 4; i++) counted({'id': i}),
            ],
          }),
      ],
    },
    _ => {
      'items': counted({
        for (var i = 0; i < n; i++) 'k$i': counted({'id': i}),
      }),
    },
  };
  await Validator(data, {pattern: 'distinct'}).run();
  return maps.fold<int>(0, (sum, map) => sum + map.reads);
}

bool _blank(Object? value) => value is String && value.trim().isEmpty;

/// Whether `distinct` failed [attribute] before this change, as it was
/// written: the parent found from the attribute's depth, a list only, the
/// items' text counted.
bool _failedBefore(Map<String, Object?> data, String attribute) {
  final lastDot = attribute.lastIndexOf('.');
  if (lastDot == -1) {
    return false;
  }
  final parentPath = attribute.substring(0, lastDot);
  final leaf = attribute.substring(lastDot + 1);
  final parentDot = parentPath.lastIndexOf('.');
  final listPath = parentDot == -1 ? null : parentPath.substring(0, parentDot);
  final list = ValidationContext.dig(data, listPath ?? parentPath);
  if (list is! List<Object?>) {
    return false;
  }
  final value = '${ValidationContext.dig(data, attribute)}';
  var seen = 0;
  for (final item in list) {
    final text =
        '${listPath == null ? item : ValidationContext.dig(item, leaf)}';
    if (text == value) {
      seen++;
    }
  }
  return seen > 1;
}
