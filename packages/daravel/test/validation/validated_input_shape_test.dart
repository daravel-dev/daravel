import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `validated()` keeps the shape of what was sent: a map stays a map with
/// the keys as sent, a list stays a list, and a key from the client never
/// decides the length of a list (Laravel builds the result with `Arr::set`
/// on PHP arrays, which are maps: `Validator.php` 12.x :642-670). A `.`
/// or `*` in a key of the data stands for itself (Laravel's placeholders,
/// `parseData` :366-385): the rules under a wildcard apply to that element.
void main() {
  Future<ValidatedData> validated(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).validate();

  group('a key from the client never sizes a list', () {
    test('a JSON object with a large number key stays that one key', () async {
      final out = await validated(
        {
          'items': {'20000000': 'a'},
        },
        {'items.*': 'string'},
      );
      expect(out.toMap(), {
        'items': {'20000000': 'a'},
      });
    });

    test('a negative or odd number key is a key, not an index', () async {
      for (final key in ['-1', '01', '1e9', '0x10', '+1', '', ' 1']) {
        final out = await validated(
          {
            'items': {key: 'a'},
          },
          {'items.*': 'string'},
        );
        expect(out.toMap(), {
          'items': {key: 'a'},
        }, reason: key);
      }
    });

    test('two levels of wildcards keep both maps', () async {
      final out = await validated(
        {
          'a': {
            '9000000': {'9000000': 'x'},
          },
        },
        {'a.*.*': 'string'},
      );
      expect(out.toMap(), {
        'a': {
          '9000000': {'9000000': 'x'},
        },
      });
    });

    test(
      'a JSON list stays a list, gaps of what was not validated null',
      () async {
        final out = await validated(
          {
            'items': [
              {'name': 'a'},
              {'name': 'b'},
            ],
          },
          {'items.*.name': 'string'},
        );
        expect(out.toMap(), {
          'items': [
            {'name': 'a'},
            {'name': 'b'},
          ],
        });
        final second = await validated(
          {
            'items': ['a', 'b', 'c'],
          },
          {'items.2': 'string'},
        );
        expect(second.toMap(), {
          'items': [null, null, 'c'],
        });
      },
    );
  });

  group('a dot or an asterisk in a key stands for itself', () {
    test('the rules under a wildcard apply to that element', () async {
      final validator = Validator(
        {
          'items': {
            'a.b': {'role': 'admin'},
          },
        },
        {'items.*.role': 'in:member'},
      );
      expect(await validator.run(), contains('items.a.b.role'));
      expect(validator.failed(), {
        'items.a.b.role': ['in'],
      });
    });

    test('a valid one comes out under its own key', () async {
      final out = await validated(
        {
          'items': {
            'a.b': {'role': 'member'},
            'c*d': {'role': 'member'},
          },
        },
        {'items.*.role': 'in:member'},
      );
      expect(out.toMap(), {
        'items': {
          'a.b': {'role': 'member'},
          'c*d': {'role': 'member'},
        },
      });
    });
  });

  group('the list accessor under array and list rules', () {
    test('array: a map keyed 0..n-1 in order reads as a list', () async {
      final out = await validated(
        {
          'items': {'0': 'a', '1': 'b'},
        },
        {'items': 'array'},
      );
      expect(out.toMap(), {
        'items': {'0': 'a', '1': 'b'},
      });
      expect(out.list<String>('items'), ['a', 'b']);
    });

    test('array: any other map is not a list', () async {
      final out = await validated(
        {
          'items': {'5': 'a'},
        },
        {'items': 'array'},
      );
      expect(() => out.list<String>('items'), throwsStateError);
    });

    test('list: an object is refused', () async {
      expect(
        () => validated(
          {
            'items': {'0': 'a', '1': 'b'},
          },
          {'items': 'list'},
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('through HTTP', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) => router
              ..post(
                '/one',
                (request) async =>
                    (await request.validate({'items.*.name': 'string'}))
                        .toMap(),
              )
              ..post(
                '/two',
                (request) async =>
                    (await request.validate({'a.*.*': 'string'})).toMap(),
              )
              ..post(
                '/exists',
                (request) async => (await request.validate({
                  // No `users` table: a query would fail, not pass.
                  'items.*.id': 'integer|exists:users,id',
                })).toMap(),
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

    test('exists is not queried after another rule failed, also under a '
        'dotted key', () async {
      final (status, body) = await send(
        Request.fake(
          method: 'POST',
          path: '/exists',
          json: {
            'items': {
              'a.b': {'id': 'abc'},
            },
          },
          headers: {'accept': 'application/json'},
        ),
      );
      expect(status, 422);
      final errors = (body! as Map)['errors'] as Map;
      expect(errors.keys, ['items.a.b.id']);
      expect((errors['items.a.b.id'] as List), hasLength(1));
    });

    test('JSON, form and multipart: the key stays a key', () async {
      final json = await send(
        Request.fake(
          method: 'POST',
          path: '/one',
          json: {
            'items': {
              '5000000': {'name': 'a'},
            },
          },
        ),
      );
      final form = await send(
        Request.fake(
          method: 'POST',
          path: '/one',
          form: {'items[5000000][name]': 'a'},
        ),
      );
      final multipart = await send(
        Request.fake(
          method: 'POST',
          path: '/one',
          form: {'items[5000000][name]': 'a'},
          files: {
            'f': UploadedFile.fromBytes(const [1], name: 'f.bin'),
          },
        ),
      );
      for (final (status, body) in [json, form, multipart]) {
        expect(status, 200);
        expect(body, {
          'items': {
            '5000000': {'name': 'a'},
          },
        });
      }
      final two = await send(
        Request.fake(
          method: 'POST',
          path: '/two',
          json: {
            'a': {
              '9000000': {'9000000': 'x'},
            },
          },
        ),
      );
      expect(two.$1, 200);
    });
  });

  test(
    '500 seeded inputs of odd keys: the result is bounded by the input, '
    'nothing but a 422 is thrown, and what comes out passed its rule',
    () async {
      const odd = [
        '-1',
        '0',
        '00',
        '01',
        '1',
        '7',
        '999999999',
        '1e9',
        '0x1f',
        '',
        ' ',
        'a.b',
        '*',
        'a*',
        '.',
        '..',
        'x',
      ];
      for (var seed = 0; seed < 500; seed++) {
        final random = Random(seed);
        var size = 0;
        Object? node(int depth) {
          size++;
          if (depth == 0 || random.nextInt(3) == 0) {
            return random.nextBool()
                ? 'v${random.nextInt(9)}'
                : random.nextInt(9);
          }
          if (random.nextBool()) {
            return [
              for (var i = random.nextInt(4); i > 0; i--) node(depth - 1),
            ];
          }
          return {
            for (var i = random.nextInt(4); i > 0; i--)
              odd[random.nextInt(odd.length)]: node(depth - 1),
          };
        }

        final data = <String, Object?>{'items': node(3)};
        final rules = <String, Object>{
          ['items.*', 'items.*.*', 'items.*.*.*'][random.nextInt(3)]: 'string',
        };
        ValidatedData? out;
        try {
          out = await Validator(data, rules).validate();
        } on ValidationException {
          continue;
        }
        var outSize = 0;
        void walk(Object? value) {
          outSize++;
          if (value is List<Object?>) {
            value.forEach(walk);
          } else if (value is Map<Object?, Object?>) {
            value.values.forEach(walk);
          }
        }

        walk(out.toMap()['items']);
        // Bounded by the input: no more nodes than were sent (a gap in a list
        // is one of the input's own elements, left out).
        expect(outSize, lessThanOrEqualTo(size), reason: 'seed $seed');
        // What came out under the rule's depth passed it: a string.
        final depth = rules.keys.single.split('.').length - 1;
        void leaves(Object? value, int level) {
          if (level == depth) {
            if (value != null) {
              expect(value, isA<String>(), reason: 'seed $seed');
            }
            return;
          }
          switch (value) {
            case final List<Object?> list:
              for (final item in list) {
                leaves(item, level + 1);
              }
            case final Map<Object?, Object?> map:
              for (final item in map.values) {
                leaves(item, level + 1);
              }
          }
        }

        leaves(out.toMap()['items'], 0);
      }
    },
  );

  test(
    '300 seeded inputs without odd keys come out as before (the old '
    'assignment, for keys that are words and lists that are lists)',
    () async {
      // The assignment before this change, as it was: an int-looking segment
      // was an index. Fed only plain word keys here, it is the reference.
      void oldAssign(
        Map<String, Object?> target,
        List<String> path,
        Object? v,
      ) {
        Object current = target;
        for (var i = 0; i < path.length; i++) {
          final segment = path[i];
          final last = i == path.length - 1;
          final index = int.tryParse(segment);
          if (current is Map<String, Object?>) {
            if (last) {
              current[segment] = v;
              return;
            }
            final nextIsIndex = int.tryParse(path[i + 1]) != null;
            current = current[segment] ??= nextIsIndex
                ? <Object?>[]
                : <String, Object?>{};
          } else if (current is List<Object?> && index != null) {
            while (current.length <= index) {
              current.add(null);
            }
            if (last) {
              current[index] = v;
              return;
            }
            final nextIsIndex = int.tryParse(path[i + 1]) != null;
            current = current[index] ??= nextIsIndex
                ? <Object?>[]
                : <String, Object?>{};
          } else {
            return;
          }
        }
      }

      const words = ['a', 'b', 'name', 'role', 'x'];
      for (var seed = 0; seed < 300; seed++) {
        final random = Random(seed);
        Object? node(int depth) {
          if (depth == 0 || random.nextInt(3) == 0) {
            return 'v${random.nextInt(9)}';
          }
          if (random.nextBool()) {
            return [
              for (var i = random.nextInt(4); i > 0; i--) node(depth - 1),
            ];
          }
          return {
            for (var i = random.nextInt(4); i > 0; i--)
              words[random.nextInt(words.length)]: node(depth - 1),
          };
        }

        final data = <String, Object?>{'items': node(3)};
        final pattern = ['items.*', 'items.*.*', 'items.*.name'][seed % 3];
        final rules = <String, Object>{pattern: 'nullable'};
        final out = (await Validator(data, rules).validate()).toMap();
        final expected = <String, Object?>{};
        for (final attribute in Validator.expandPattern(data, pattern)) {
          if (!ValidationContext.exists(data, attribute)) {
            continue;
          }
          oldAssign(
            expected,
            attribute.split('.'),
            ValidationContext.dig(data, attribute),
          );
        }
        expect(out, expected, reason: 'seed $seed: $data');
      }
    },
  );

  group('rules see the data as sent', () {
    test('rules that compare keys compare the keys as sent', () async {
      final data = <String, Object?>{
        'meta': {'a.b': 1, 'c*': 2},
      };
      final out = await validated(data, {
        'meta': ['required_array_keys:a.b,c*', 'array:a.b,c*'],
      });
      expect(out.toMap(), data);
    });

    test('a closure rule sees the attribute and the value as sent', () async {
      final seen = <String>[];
      await validated(
        {
          'items': {
            'a.b': {'k.1': 'x'},
          },
        },
        {
          'items.*': [
            Rules.custom((c) {
              seen
                ..add(c.attribute)
                ..addAll((c.value! as Map).keys.cast<String>());
              return null;
            }),
          ],
        },
      );
      expect(seen, ['items.a.b', 'k.1']);
    });

    test(
      'a forEach callback sees the value and the attribute as sent',
      () async {
        final seen = <String>[];
        await validated(
          {
            'items': {
              'a.b': {'k*': 'x'},
            },
          },
          {
            'items.*': [
              Rules.forEach((item) {
                seen
                  ..add(item.attribute)
                  ..addAll((item.value! as Map).keys.cast<String>());
                return const <Rule>[];
              }),
            ],
          },
        );
        expect(seen, ['items.a.b', 'k*']);
      },
    );
  });

  test('500 seeded 422 answers never hold a placeholder, in keys, messages '
      'or parameters', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) => router.post(
            '/check',
            (request) async => (await request.validate({
              'items.*': 'array',
              'items.*.role': 'required|in:member,owner',
              'items.*.code': 'same:items.*.role',
              'items.*.size': 'integer|min:3',
              'items.*.*': 'string|max:2',
            })).toMap(),
          ),
        )
        .create();
    await app.boot();
    try {
      const odd = ['a.b', '*', 'x*y', '.', 'k.1.2', 'n', '0', '1e9'];
      for (var seed = 0; seed < 500; seed++) {
        final random = Random(seed);
        final items = <String, Object?>{
          for (var i = random.nextInt(4) + 1; i > 0; i--)
            odd[random.nextInt(odd.length)]: {
              for (var j = random.nextInt(4); j > 0; j--)
                ['role', 'code', 'size', odd[random.nextInt(odd.length)]][random
                    .nextInt(4)]: [
                  'admin',
                  'member',
                  7,
                  'toolong',
                ][random.nextInt(4)],
            },
        };
        final response = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/check',
            json: {'items': items},
            headers: {'accept': 'application/json'},
          ),
        );
        final body = await response.bodyText();
        expect(response.status, anyOf(200, 422), reason: 'seed $seed');
        expect(body, isNot(contains('__dot__')), reason: 'seed $seed: $body');
        expect(
          body,
          isNot(contains('__asterisk__')),
          reason: 'seed $seed: $body',
        );
      }
    } finally {
      await app.shutdown();
    }
  });

  test('forEach over n elements does linear work, also with a dotted key '
      'in the input (2 000 against 8 000)', () async {
    // The work is counted (the map entries the validator re-keys), not
    // timed: a count does not vary with a shared CI machine.
    Future<int> entries(int n, {required bool dotted}) async {
      final data = <String, Object?>{
        'items': [
          for (var i = 0; i < n; i++) {'name': 'v$i'},
        ],
        if (dotted) 'meta': {'a.b': 1},
      };
      final rules = <String, Object>{
        'items.*': [
          Rules.forEach((item) => [Rules.custom((_) => null)]),
        ],
        'items.*.name': 'string',
      };
      final before = Validator.rekeyedEntries;
      await Validator(data, rules).validate();
      return Validator.rekeyedEntries - before;
    }

    for (final dotted in [false, true]) {
      final small = await entries(2000, dotted: dotted);
      final large = await entries(8000, dotted: dotted);
      final ratio = large / small;
      print(
        'forEach ${dotted ? 'with' : 'without'} a dotted key: 2000 re-key '
        '$small entries, 8000 re-key $large, ratio ${ratio.toStringAsFixed(2)}',
      );
      // Linear is 4; decoding the parent once per element is about 16.
      expect(ratio, lessThan(4.1), reason: dotted ? 'dotted' : 'plain');
    }
  });
}
