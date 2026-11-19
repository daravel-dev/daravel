import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/key_pattern.dart';
import 'package:daravel/src/validation/php_compare.dart';
import 'package:test/test.dart';

/// An empty key is a key at every level, as in Laravel: `Arr::dot` joins
/// it like any other (`$prefix.$key`, so `{"": {"role": 1}}` is `.role`,
/// `laravel/framework` 12.x `src/Illuminate/Collections/Arr.php`
/// :184-206), a rule's `*` matches it (`[^\.]*`,
/// `ValidationRuleParser::explodeWildcardRules` :161 and
/// `ValidationData::extractValuesForWildcards` :58), `in_array`'s `*`
/// matches it (`Str::is`, `.*`, `src/Illuminate/Support/Str.php` :546),
/// and `distinct`'s does not (`[^.]+`,
/// `ValidatesAttributes::extractDistinctValues` :925).
void main() {
  Future<Map<String, List<String>>> errors(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).run();

  group('a wildcard of a rule key matches an empty key', () {
    final cases = <(String, Map<String, Object?>, String)>[
      ('*', {'': 'bad'}, ''),
      (
        '*.role',
        {
          '': {'role': 'bad'},
        },
        '.role',
      ),
      (
        '*.*',
        {
          '': {'': 'bad'},
        },
        '.',
      ),
      (
        '*.*.role',
        {
          '': {
            '': {'role': 'bad'},
          },
        },
        '..role',
      ),
      (
        'a.*.b',
        {
          'a': {
            '': {'b': 'bad'},
          },
        },
        'a..b',
      ),
      (
        'a.*.*.b',
        {
          'a': {
            '': {
              '': {'b': 'bad'},
            },
          },
        },
        'a...b',
      ),
    ];

    for (final (pattern, data, key) in cases) {
      test('$pattern against ${jsonEncode(data)} fails under "$key"', () async {
        expect((await errors(data, {pattern: 'in:ok'})).keys, [key]);
        final good = jsonDecode(
          jsonEncode(data).replaceAll('"bad"', '"ok"'),
        ) as Map<String, Object?>;
        final out = await Validator(good, {pattern: 'in:ok'}).validate();
        expect(out.toMap(), good);
      });
    }

    test('expandPattern writes the empty key as Arr::dot does', () {
      expect(
        Validator.expandPattern({
          '': {'role': 1},
          'x': {'role': 2},
        }, '*.role'),
        ['.role', 'x.role'],
      );
      expect(
        Validator.expandPattern({
          '': ['a', 'b'],
        }, '*.*'),
        ['.0', '.1'],
      );
    });

    test('a forEach under an empty key sees its own value', () async {
      final seen = <String, Object?>{};
      await Validator(
        {
          '': {'role': 'admin'},
        },
        {
          '*': [
            Rules.forEach((item) {
              seen[item.attribute] = item.value;
              return const <Rule>[];
            }),
          ],
        },
      ).run();
      expect(seen, {
        '': {'role': 'admin'},
      });
    });
  });

  group('KeyPattern is the pattern Laravel writes', () {
    test('distinct: a `*` never matches an empty key', () {
      final pattern = KeyPattern('*.a.*', crossDots: false);
      expect(pattern.matches('.a.x'), isFalse);
      expect(pattern.matches('k.a.'), isFalse);
      expect(pattern.matches('k.a.x'), isTrue);
    });

    test('in_array: a `*` matches an empty key', () {
      final pattern = KeyPattern('*.code', crossDots: true);
      expect(pattern.matches('.code'), isTrue);
      expect(pattern.matches('code'), isFalse);
    });
  });

  group('distinct and in_array see the empty key where Arr::dot puts it', () {
    test('in_array: data under an empty key is not the named field', () async {
      final result = await errors(
        {
          'allowed': [
            {'code': 'USER'},
          ],
          '': {
            'allowed': [
              {'code': 'USER'},
              {'code': 'ADMIN'},
            ],
          },
          'pick': 'ADMIN',
        },
        {'allowed': 'array', 'pick': 'required|in_array:allowed.*.code'},
      );
      expect(result.keys, ['pick']);
    });

    test('in_array: a top-level `*` takes the empty key', () async {
      final result = await errors(
        {
          '': {'code': 'vip'},
          'pick': 'vip',
        },
        {'pick': 'required|in_array:*.code'},
      );
      expect(result, isEmpty);
    });

    test('distinct: an empty key does not shadow the named field', () async {
      final result = await errors(
        {
          'items': [
            {'id': '1'},
            {'id': '2'},
          ],
          '': {
            'items': [
              {'id': '2'},
            ],
          },
        },
        {'items.*.id': 'distinct'},
      );
      expect(result, isEmpty);
    });

    test('distinct: values under an empty key are not compared, as in '
        'Laravel (`[^.]+`)', () async {
      expect(
        await errors(
          {
            '': {
              'a': {'x': 'DUP', 'y': 'DUP'},
            },
          },
          {'*.a.*': 'distinct'},
        ),
        isEmpty,
      );
      expect(
        await errors(
          {
            'items': {
              '': {
                'a': {'x': 'DUP', 'y': 'DUP'},
              },
            },
          },
          {'items.*.a.*': 'distinct'},
        ),
        isEmpty,
      );
      // The same values under a named key are compared.
      expect(
        (await errors(
          {
            'g': {
              'a': {'x': 'DUP', 'y': 'DUP'},
            },
          },
          {'*.a.*': 'distinct'},
        )).keys,
        ['g.a.x', 'g.a.y'],
      );
    });
  });

  test('3000 seeded inputs with empty keys decide as Laravel writes it', () async {
    // Arr::dot, with the empty key joined like any other.
    Map<String, Object?> dot(Object? value, [String? prefix]) {
      final entries = switch (value) {
        final List<Object?> list when list.isNotEmpty => [
          for (var i = 0; i < list.length; i++) MapEntry('$i', list[i]),
        ],
        final Map<String, Object?> map when map.isNotEmpty => map.entries,
        _ => null,
      };
      if (entries == null) {
        return {prefix ?? '': value};
      }
      return {
        for (final MapEntry(:key, :value) in entries)
          ...dot(value, prefix == null ? key : '$prefix.$key'),
      };
    }

    RegExp regex(String pattern, String star, {bool whole = true}) => RegExp(
      '^${pattern.split('*').map(RegExp.escape).join(star)}${whole ? r'$' : ''}',
      dotAll: true,
    );

    // explodeWildcardRules: each flattened key, matched at its start.
    Set<String> expand(Map<String, Object?> data, String pattern) => {
      for (final key in dot(data).keys)
        if (regex(pattern, r'[^.]*', whole: false).firstMatch(key)
            case final match?)
          match[0]!,
    };

    Iterable<Object?> leaves(
      Map<String, Object?> data,
      String pattern,
      String star, {
      String? except,
    }) => [
      for (final MapEntry(:key, :value) in dot(data).entries)
        if (key != except && regex(pattern, star).hasMatch(key)) value,
    ];

    bool checked(Map<String, Object?> data, String attribute) {
      if (!ValidationContext.exists(data, attribute)) {
        return false;
      }
      final value = ValidationContext.dig(data, attribute);
      return !(value is String && value.trim().isEmpty);
    }

    const keys = ['', '', 'a', 'items', 'x'];
    const values = <Object?>['1', 1, 1.0, 'a', 'A', 2, '2', true, null];
    const patterns = [
      '*',
      '*.a',
      '*.*',
      'items.*',
      'items.*.a',
      '*.a.*',
      '*.*.a',
      'items.*.*',
    ];
    final random = Random(20261119);
    Object? node(int depth) {
      if (depth == 0 || random.nextInt(4) == 0) {
        return values[random.nextInt(values.length)];
      }
      if (random.nextInt(4) == 0) {
        return [for (var i = random.nextInt(3); i > 0; i--) node(depth - 1)];
      }
      return <String, Object?>{
        for (var i = random.nextInt(4); i > 0; i--)
          keys[random.nextInt(keys.length)]: node(depth - 1),
      };
    }

    var compared = 0;
    var failing = 0;
    var withEmpty = 0;
    for (var i = 0; i < 3000; i++) {
      final data = <String, Object?>{
        for (var j = 1 + random.nextInt(3); j > 0; j--)
          keys[random.nextInt(keys.length)]: node(3),
      };
      final pattern = patterns[random.nextInt(patterns.length)];
      final inArray = random.nextInt(3) == 0;
      final Map<String, Object?> input;
      final Map<String, Object> rules;
      final expected = <String>{};
      if (inArray) {
        final pick = values[random.nextInt(values.length)];
        input = {...data, 'pick': pick};
        rules = {'pick': 'in_array:$pattern'};
        if (checked(input, 'pick') &&
            !leaves(input, pattern, '.*').any((v) => phpIdentical(pick, v))) {
          expected.add('pick');
        }
      } else {
        input = data;
        final strict = random.nextBool();
        rules = {pattern: strict ? 'distinct:strict' : 'distinct'};
        for (final attribute in expand(input, pattern)) {
          if (!checked(input, attribute)) {
            continue;
          }
          final value = ValidationContext.dig(input, attribute);
          final others = leaves(input, pattern, '[^.]+', except: attribute);
          if (others.any(
            (other) => strict
                ? phpIdentical(value, other)
                : phpLooseEquals(value, other),
          )) {
            expected.add(attribute);
          }
        }
      }
      final result = await Validator(input, rules).run();
      expect(
        result.keys.toSet(),
        expected,
        reason: '${rules.values.single} ${jsonEncode(input)}',
      );
      compared++;
      if (expected.isNotEmpty) {
        failing++;
      }
      if (dot(input).keys.any((k) => k.startsWith('.') || k.contains('..'))) {
        withEmpty++;
      }
    }
    expect(compared, 3000);
    expect(failing, greaterThan(300));
    expect(withEmpty, greaterThan(1000));
  });

  group('through HTTP', () {
    late Application app;

    setUp(() async {
      Future<Object?> check(Request request, Map<String, Object> rules) async =>
          (await request.validate(rules)).toMap();
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) => router
              ..post(
                '/top-wild-role',
                (request) => check(request, {'*.role': 'in:user'}),
              )
              ..post(
                '/in-array-spoof',
                (request) => check(request, {
                  'allowed': 'array',
                  'pick': 'required|in_array:allowed.*.code',
                }),
              )
              ..post(
                '/in-array-top-empty',
                (request) =>
                    check(request, {'pick': 'required|in_array:*.code'}),
              )
              ..post(
                '/distinct-top-empty',
                (request) => check(request, {'*.a.*': 'distinct'}),
              )
              ..post(
                '/distinct-mid-empty',
                (request) => check(request, {'items.*.a.*': 'distinct'}),
              )
              ..post(
                '/distinct-collision',
                (request) => check(request, {'items.*.id': 'distinct'}),
              ),
          )
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    Future<(int, Object?)> post(String path, Map<String, Object?> json) async {
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: path,
          json: json,
          headers: {'accept': 'application/json'},
        ),
      );
      return (response.status, jsonDecode(await response.bodyText()));
    }

    test('*.role under an empty key is validated', () async {
      final (status, body) = await post('/top-wild-role', {
        '': {'role': 'admin'},
      });
      expect(status, 422);
      expect(((body! as Map)['errors'] as Map).keys, ['.role']);
      expect(
        await post('/top-wild-role', {
          '': {'role': 'user'},
        }),
        (
          200,
          {
            '': {'role': 'user'},
          },
        ),
      );
    });

    test('in_array cannot be fed from under an empty key', () async {
      final (status, body) = await post('/in-array-spoof', {
        'allowed': [
          {'code': 'USER'},
        ],
        '': {
          'allowed': [
            {'code': 'USER'},
            {'code': 'ADMIN'},
          ],
        },
        'pick': 'ADMIN',
      });
      expect(status, 422);
      expect(((body! as Map)['errors'] as Map).keys, ['pick']);
    });

    test('in_array:*.code takes a value under an empty key', () async {
      final (status, _) = await post('/in-array-top-empty', {
        '': {'code': 'vip'},
        'pick': 'vip',
      });
      expect(status, 200);
    });

    test('distinct: as Laravel, values under an empty key are not '
        'compared', () async {
      expect(
        (await post('/distinct-top-empty', {
          '': {
            'a': {'x': 'DUP', 'y': 'DUP'},
          },
        })).$1,
        200,
      );
      expect(
        (await post('/distinct-mid-empty', {
          'items': {
            '': {
              'a': {'x': 'DUP', 'y': 'DUP'},
            },
          },
        })).$1,
        200,
      );
    });

    test('distinct: an empty key does not shadow items', () async {
      final (status, body) = await post('/distinct-collision', {
        'items': [
          {'id': '1'},
          {'id': '2'},
        ],
        '': {
          'items': [
            {'id': '2'},
          ],
        },
      });
      expect(status, 200, reason: '$body');
    });
  });
}
