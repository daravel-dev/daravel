import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `validated()` keeps the shape of what was sent: a map stays a map with
/// the keys as sent, a list stays a list, and a key from the client never
/// decides the length of a list (Laravel builds the result with `Arr::set`
/// on PHP arrays, which are maps: `Validator.php` 12.x :642-670). A list
/// index is read only in its canonical form (`'1'`, never `'01'`, `'+1'`
/// or `'-1'`), as PHP's `array_key_exists` reads one.
void main() {
  Future<ValidatedData> validated(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).validate();

  group('a key from the client never sizes a list', () {
    test('a JSON object with a large number key stays that one key', () async {
      for (final key in ['2000000', '10000000', '20000000']) {
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
            '5000000': {
              'b': {'5000000': 'x'},
            },
          },
        },
        {'a.*.b.*': 'string'},
      );
      expect(out.toMap(), {
        'a': {
          '5000000': {
            'b': {'5000000': 'x'},
          },
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

  group('a list index is read only in its canonical form', () {
    test('a rule key with a non-canonical index names no element', () async {
      for (final index in ['01', '+1', '-1', '1e0', '0x1', ' 1', '1 ', '9']) {
        final validator = Validator(
          {
            'items': ['zero', 'one'],
          },
          {'items.$index': 'required'},
        );
        expect(await validator.run(), contains('items.$index'), reason: index);
      }
    });

    test('a negative index before a wildcard is not a 500', () async {
      final validator = Validator(
        {
          'items': ['a'],
        },
        {'items.-1.*': 'string'},
      );
      expect(await validator.run(), isEmpty);
      expect(validator.validated().toMap(), isEmpty);
    });

    test('exclude under a non-canonical index removes nothing', () async {
      for (final index in ['01', '+1', '-1', '1e0']) {
        final out = await validated(
          {
            'items': [
              {'secret': 's0'},
              {'secret': 's1'},
            ],
          },
          {'items.$index.secret': 'exclude', 'items.*.secret': 'string'},
        );
        expect(out.toMap(), {
          'items': [
            {'secret': 's0'},
            {'secret': 's1'},
          ],
        }, reason: index);
      }
    });

    test('exclude under the canonical index still removes', () async {
      final out = await validated(
        {
          'items': [
            {'secret': 's0'},
            {'secret': 's1'},
          ],
        },
        {'items.1.secret': 'exclude', 'items.*.secret': 'string'},
      );
      // Laravel's `Arr::forget` leaves `items.1` without `secret`, and
      // `validated()` builds only what a rule names.
      expect(out.toMap(), {
        'items': [
          {'secret': 's0'},
        ],
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
      for (final map in [
        {'5': 'a'},
        {'1': 'b', '0': 'a'},
        {'0': 'a', '01': 'b'},
      ]) {
        final out = await validated({'items': map}, {'items': 'array'});
        expect(() => out.list<String>('items'), throwsStateError);
      }
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

  test('a dotted data key still reads as levels (closed in 1.28.0)', () async {
    // Locks the behavior as it is: Laravel treats `a.b` as one key here
    // (placeholders, `Validator::parseData`); this version still looks
    // `items.a.b.role` up as three levels, finds nothing, and the rule is
    // not run. Closed in 1.28.0 with structured input paths.
    final validator = Validator(
      {
        'items': {
          'a.b': {'role': 'admin'},
        },
      },
      {'items.*.role': 'in:member'},
    );
    expect(await validator.run(), isEmpty);
    expect(validator.validated().toMap(), isEmpty);
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
                    (await request.validate({'items.*': 'string'})).toMap(),
              )
              ..post(
                '/name',
                (request) async =>
                    (await request.validate({'items.*.name': 'string'}))
                        .toMap(),
              )
              ..post(
                '/two',
                (request) async =>
                    (await request.validate({'a.*.b.*': 'string'})).toMap(),
              )
              ..post(
                '/negative',
                (request) async =>
                    (await request.validate({'items.-1.*': 'string'})).toMap(),
              )
              ..post(
                '/exclude',
                (request) async => (await request.validate({
                  'items.01.secret': 'exclude',
                  'items.*.secret': 'required|string',
                })).toMap(),
              )
              ..post(
                '/array',
                (request) async =>
                    (await request.validate({'items': 'array'})).toMap(),
              )
              ..post(
                '/list',
                (request) async =>
                    (await request.validate({'items': 'list'})).toMap(),
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

    test('JSON keys of any size come back as the same one key', () async {
      for (final key in ['2000000', '10000000', '20000000', '-1']) {
        final (status, body) = await send(
          Request.fake(
            method: 'POST',
            path: '/one',
            json: {
              'items': {key: 'a'},
            },
          ),
        );
        expect(status, 200, reason: key);
        expect(body, {
          'items': {key: 'a'},
        }, reason: key);
      }
    });

    test('a sparse form index is a map: array takes it, list answers '
        '422', () async {
      // `items[1][name]` alone: the form parser gives a map keyed `1`
      // (only `0`, `1`, ... in order become a list); `validated()` used
      // to pad it into `[null, {...}]`.
      Request form(String path) => Request.fake(
        method: 'POST',
        path: path,
        form: {'items[1][name]': 'a'},
        headers: {'accept': 'application/json'},
      );
      final (arrayStatus, arrayBody) = await send(form('/array'));
      expect(arrayStatus, 200);
      expect(arrayBody, {
        'items': {
          '1': {'name': 'a'},
        },
      });
      final (listStatus, listBody) = await send(form('/list'));
      expect(listStatus, 422);
      expect(((listBody! as Map)['errors'] as Map).keys, ['items']);
      // Under a wildcard rule (`items.*.name`) the padding happened: the
      // same map now comes back as it was sent.
      final (nameStatus, nameBody) = await send(form('/name'));
      expect(nameStatus, 200);
      expect(nameBody, {
        'items': {
          '1': {'name': 'a'},
        },
      });
    });

    test('form and multipart: the key stays a key', () async {
      final form = await send(
        Request.fake(
          method: 'POST',
          path: '/name',
          form: {'items[5000000][name]': 'a'},
        ),
      );
      final multipart = await send(
        Request.fake(
          method: 'POST',
          path: '/name',
          form: {'items[5000000][name]': 'a'},
          files: {
            'f': UploadedFile.fromBytes(const [1], name: 'f.bin'),
          },
        ),
      );
      for (final (status, body) in [form, multipart]) {
        expect(status, 200);
        expect(body, {
          'items': {
            '5000000': {'name': 'a'},
          },
        });
      }
    });

    test('two levels of number keys stay maps', () async {
      final (status, body) = await send(
        Request.fake(
          method: 'POST',
          path: '/two',
          json: {
            'a': {
              '5000000': {
                'b': {'5000000': 'x'},
              },
            },
          },
        ),
      );
      expect(status, 200);
      expect(body, {
        'a': {
          '5000000': {
            'b': {'5000000': 'x'},
          },
        },
      });
    });

    test('a negative index before a wildcard answers 200', () async {
      final (status, _) = await send(
        Request.fake(
          method: 'POST',
          path: '/negative',
          json: {
            'items': ['a'],
          },
        ),
      );
      expect(status, 200);
    });

    test('exclude under items.01 keeps items.1', () async {
      final (status, body) = await send(
        Request.fake(
          method: 'POST',
          path: '/exclude',
          json: {
            'items': [
              {'secret': 's0'},
              {'secret': 's1'},
            ],
          },
          headers: {'accept': 'application/json'},
        ),
      );
      expect(status, 200, reason: '$body');
      expect(body, {
        'items': [
          {'secret': 's0'},
          {'secret': 's1'},
        ],
      });
    });
  });

  test(
    '500 seeded inputs of odd keys: the result is bounded by the input, '
    'nothing but a 422 is thrown, and what comes out passed its rule',
    () async {
      // Keys with a `.` or `*` are left out: they are closed in 1.28.0.
      const odd = [
        '-1',
        '0',
        '00',
        '01',
        '+1',
        '1',
        '7',
        '999999999',
        '1e9',
        '0x1f',
        '',
        ' ',
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
        // Bounded by the input: no more nodes than were sent (a gap in a
        // list is one of the input's own elements, left out).
        expect(outSize, lessThanOrEqualTo(size), reason: 'seed $seed');
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

  group('work grows linearly with the input (n against 4n)', () {
    // The work is counted (reads of the input's maps and lists), not timed:
    // a count does not vary with a shared CI machine.
    Future<int> reads(
      Object? Function(ReadCounter) build,
      String pattern,
    ) async {
      final counter = ReadCounter();
      final data = build(counter)! as Map<String, Object?>;
      await Validator(data, {pattern: 'nullable'}).validate();
      return counter.reads;
    }

    final shapes = <String, (Object? Function(ReadCounter, int), String)>{
      'a map of n number keys': (
        (c, n) => c.map({
          'items': c.map({for (var i = 0; i < n; i++) '${i * 7}': 'a'}),
        }),
        'items.*',
      ),
      'a list of n items': (
        (c, n) => c.map({
          'items': c.list([
            for (var i = 0; i < n; i++) c.map({'name': 'v$i'}),
          ]),
        }),
        'items.*.name',
      ),
      'n items under an empty key each': (
        (c, n) => c.map({
          'items': c.list([
            for (var i = 0; i < n; i++)
              c.map({
                '': c.map({'role': 'r$i'}),
              }),
          ]),
        }),
        'items.*.*.role',
      ),
      'n maps of n/4 keys, two wildcards': (
        (c, n) => c.map({
          'items': c.map({
            for (var i = 0; i < 4; i++)
              '$i': c.map({for (var j = 0; j < n; j++) '0$j': 'a'}),
          }),
        }),
        'items.*.*',
      ),
    };

    for (final MapEntry(key: name, value: (build, pattern)) in shapes.entries) {
      test(name, () async {
        final small = await reads((c) => build(c, 1000), pattern);
        final large = await reads((c) => build(c, 4000), pattern);
        final ratio = large / small;
        // Linear is 4; anything that walks the input once per element is
        // about 16.
        expect(ratio, inInclusiveRange(1, 4.2), reason: '$small → $large');
      });
    }
  });
}

/// Counts the reads of the maps and lists it builds.
final class ReadCounter {
  int reads = 0;

  Map<String, Object?> map(Map<String, Object?> source) =>
      _CountingMap(source, this);

  List<Object?> list(List<Object?> source) => _CountingList(source, this);
}

final class _CountingMap extends MapBase<String, Object?> {
  _CountingMap(this._source, this._counter);

  final Map<String, Object?> _source;
  final ReadCounter _counter;

  @override
  Object? operator [](Object? key) {
    _counter.reads++;
    return _source[key];
  }

  @override
  bool containsKey(Object? key) {
    _counter.reads++;
    return _source.containsKey(key);
  }

  @override
  void operator []=(String key, Object? value) => _source[key] = value;

  @override
  void clear() => _source.clear();

  @override
  Iterable<String> get keys => _source.keys.map((key) {
    _counter.reads++;
    return key;
  });

  @override
  Object? remove(Object? key) => _source.remove(key);
}

final class _CountingList extends ListBase<Object?> {
  _CountingList(this._source, this._counter);

  final List<Object?> _source;
  final ReadCounter _counter;

  @override
  int get length => _source.length;

  @override
  set length(int value) => _source.length = value;

  @override
  Object? operator [](int index) {
    _counter.reads++;
    return _source[index];
  }

  @override
  void operator []=(int index, Object? value) => _source[index] = value;
}
