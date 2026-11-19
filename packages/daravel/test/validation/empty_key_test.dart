import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// An empty key is a key at every level, as in Laravel: `Arr::dot` joins
/// it like any other (`$prefix.$key`, so `{"": {"role": 1}}` is `.role`,
/// `laravel/framework` 12.x `src/Illuminate/Collections/Arr.php`
/// :184-206), and a rule's `*` matches it (`[^\.]*`,
/// `ValidationRuleParser::explodeWildcardRules` :161 and
/// `ValidationData::extractValuesForWildcards` :58).
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

    test('a dependent rule finds its sibling under the empty key', () async {
      final rules = <String, Object>{
        '*.role': 'required_if:*.type,admin',
        '*.pin': 'confirmed',
      };
      expect(
        (await errors({
          '': {'type': 'admin', 'pin': '1', 'pin_confirmation': '2'},
          'x': {'type': 'user'},
        }, rules)).keys.toSet(),
        {'.role', '.pin'},
      );
      expect(
        await errors({
          '': {
            'type': 'admin',
            'role': 'r',
            'pin': '1',
            'pin_confirmation': '1',
          },
        }, rules),
        isEmpty,
      );
    });

    test('distinct compares a list under an empty key', () async {
      // This version's distinct compares the items of the enclosing list;
      // under an empty key that list was never reached.
      expect(
        (await errors(
          {
            '': ['a', 'a'],
          },
          {'*.*': 'distinct'},
        )).keys.toSet(),
        {'.0', '.1'},
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
            api: (router) => router.post(
              '/top-wild-role',
              (request) async =>
                  (await request.validate({'*.role': 'in:user'})).toMap(),
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
      final (okStatus, okBody) = await post('/top-wild-role', {
        '': {'role': 'user'},
      });
      expect(okStatus, 200);
      expect(okBody, {
        '': {'role': 'user'},
      });
    });
  });
}
