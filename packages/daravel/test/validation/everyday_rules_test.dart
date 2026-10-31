import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

enum Status { draft, published }

/// The rules of `Illuminate\Validation\Concerns\ValidatesAttributes` that
/// Laravel applications use every day.
void main() {
  Future<Map<String, List<String>>> errors(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).run();

  Future<bool> ok(Map<String, Object?> data, String rule) async =>
      (await errors(data, {'a': rule})).isEmpty;

  group('gt, gte, lt, lte', () {
    test('a number against a number', () async {
      expect(await ok({'a': 5}, 'gt:3'), isTrue);
      expect(await ok({'a': 3}, 'gt:3'), isFalse);
      expect(await ok({'a': 3}, 'gte:3'), isTrue);
      expect(await ok({'a': '2'}, 'lt:3'), isTrue);
      expect(await ok({'a': 3}, 'lte:3'), isTrue);
      expect(await ok({'a': 4}, 'lte:3'), isFalse);
    });

    test('text against a number fails, whatever its length', () async {
      expect(await ok({'a': 'abcdef'}, 'gt:3'), isFalse);
    });

    test('decimals compare exactly', () async {
      expect(await ok({'a': '0.3'}, 'gte:0.3'), isTrue);
      expect(
        await ok({'a': '12345678901234567890.2'}, 'gt:12345678901234567890.1'),
        isTrue,
      );
    });

    test('against a field of the same type', () async {
      expect(await ok({'a': 'abcd', 'b': 'ab'}, 'gt:b'), isTrue);
      expect(
        await ok({
          'a': [1],
          'b': [1, 2],
        }, 'gt:b'),
        isFalse,
      );
      expect(await ok({'a': 5, 'b': 2}, 'gt:b'), isTrue);
      expect(await ok({'a': '5', 'b': 2}, 'gt:b'), isTrue);
    });

    test('other types, or a missing field, fail', () async {
      expect(
        await ok({
          'a': 'abc',
          'b': [1],
        }, 'gt:b'),
        isFalse,
      );
      expect(await ok({'a': 'abc'}, 'gt:b'), isFalse);
    });

    test('the message names the size, or the field', () async {
      expect((await errors({'a': 1}, {'a': 'gt:3'}))['a'], [
        'The a field must be greater than 3.',
      ]);
      expect((await errors({'a': 'x', 'b': 'abc'}, {'a': 'gt:b'}))['a'], [
        'The a field must be greater than 3 characters.',
      ]);
      expect((await errors({'a': 1}, {'a': 'gt:other_field'}))['a'], [
        'The a field must be greater than other field.',
      ]);
    });
  });

  test('decimal', () async {
    expect(await ok({'a': '1.25'}, 'decimal:2'), isTrue);
    expect(await ok({'a': '1.2'}, 'decimal:2'), isFalse);
    expect(await ok({'a': '1'}, 'decimal:0,2'), isTrue);
    expect(await ok({'a': '1.234'}, 'decimal:0,2'), isFalse);
    expect(await ok({'a': 'abc'}, 'decimal:0,2'), isFalse);
    expect(await ok({'a': '1e2'}, 'decimal:0,2'), isFalse);
    expect((await errors({'a': '1'}, {'a': 'decimal:1,2'}))['a'], [
      'The a field must have 1-2 decimal places.',
    ]);
  });

  test('multiple_of is exact where floats are not', () async {
    expect(await ok({'a': '0.3'}, 'multiple_of:0.1'), isTrue);
    expect(await ok({'a': 10}, 'multiple_of:5'), isTrue);
    expect(await ok({'a': 0}, 'multiple_of:5'), isTrue);
    expect(await ok({'a': 7}, 'multiple_of:5'), isFalse);
    expect(await ok({'a': 5}, 'multiple_of:0'), isFalse);
    expect(await ok({'a': 'x'}, 'multiple_of:5'), isFalse);
  });

  test('min_digits and max_digits', () async {
    expect(await ok({'a': '123'}, 'min_digits:3'), isTrue);
    expect(await ok({'a': '12'}, 'min_digits:3'), isFalse);
    expect(await ok({'a': '12a'}, 'min_digits:3'), isFalse);
    expect(await ok({'a': 123}, 'max_digits:3'), isTrue);
    expect(await ok({'a': 1234}, 'max_digits:3'), isFalse);
  });

  test('date_equals', () async {
    expect(await ok({'a': '2026-10-31'}, 'date_equals:2026-10-31'), isTrue);
    expect(await ok({'a': '2026-10-30'}, 'date_equals:2026-10-31'), isFalse);
    expect(
      await ok({'a': '2026-10-31', 'b': '2026-10-31'}, 'date_equals:b'),
      isTrue,
    );
  });

  test('timezone', () async {
    expect(await ok({'a': 'Asia/Makassar'}, 'timezone'), isTrue);
    expect(await ok({'a': 'UTC'}, 'timezone'), isTrue);
    expect(await ok({'a': 'Mars/Base'}, 'timezone'), isFalse);
    expect(await ok({'a': 'Asia/Makassar'}, 'timezone:Asia'), isTrue);
    expect(await ok({'a': 'Asia/Makassar'}, 'timezone:Europe'), isFalse);
  });

  group('conditional presence', () {
    test('prohibited_if and prohibited_unless', () async {
      expect(await ok({'a': 'x', 'b': 'yes'}, 'prohibited_if:b,yes'), isFalse);
      expect(await ok({'a': 'x', 'b': 'no'}, 'prohibited_if:b,yes'), isTrue);
      expect(await ok({'a': '', 'b': 'yes'}, 'prohibited_if:b,yes'), isTrue);
      expect(
        await ok({'a': 'x', 'b': 'no'}, 'prohibited_unless:b,yes'),
        isFalse,
      );
      expect(
        await ok({'a': 'x', 'b': 'yes'}, 'prohibited_unless:b,yes'),
        isTrue,
      );
    });

    test('prohibits', () async {
      expect(await ok({'a': 'x', 'b': 'y'}, 'prohibits:b'), isFalse);
      expect(await ok({'a': 'x'}, 'prohibits:b'), isTrue);
      expect(
        (await errors({'a': 'x', 'b_c': 'y'}, {'a': 'prohibits:b_c'}))['a'],
        ['The a field prohibits b c from being present.'],
      );
    });

    test('required_with_all and required_without_all', () async {
      expect(await ok({'b': 1, 'c': 1}, 'required_with_all:b,c'), isFalse);
      expect(await ok({'b': 1}, 'required_with_all:b,c'), isTrue);
      expect(await ok({}, 'required_without_all:b,c'), isFalse);
      expect(await ok({'b': 1}, 'required_without_all:b,c'), isTrue);
    });

    test('required_if_accepted', () async {
      expect(await ok({'b': 'yes'}, 'required_if_accepted:b'), isFalse);
      expect(await ok({'b': 'no'}, 'required_if_accepted:b'), isTrue);
    });

    test('present_if', () async {
      expect(await ok({'b': '1'}, 'present_if:b,1'), isFalse);
      expect(await ok({'b': '1', 'a': ''}, 'present_if:b,1'), isTrue);
      expect(await ok({'b': '2'}, 'present_if:b,1'), isTrue);
    });
  });

  group('exclude', () {
    Future<Map<String, Object?>> kept(
      Map<String, Object?> data,
      Map<String, Object> rules,
    ) async => (await Validator(data, rules).validate()).toMap();

    test('leaves the attribute out, with no error', () async {
      expect(
        await kept({'a': 'x', 'b': 'y'}, {'a': 'exclude', 'b': 'string'}),
        {'b': 'y'},
      );
    });

    test('exclude_if stops the rules after it', () async {
      final data = {'type': 'free', 'price': 'not a number'};
      expect(
        await kept(data, {
          'type': 'required',
          'price': 'exclude_if:type,free|required|numeric',
        }),
        {'type': 'free'},
      );
    });

    test('exclude_unless, exclude_with, exclude_without', () async {
      expect(
        await kept({'a': 1, 'b': 'x'}, {'a': 'exclude_unless:b,y'}),
        isEmpty,
      );
      expect(await kept({'a': 1, 'b': 'y'}, {'a': 'exclude_unless:b,y'}), {
        'a': 1,
      });
      expect(await kept({'a': 1, 'b': 'x'}, {'a': 'exclude_with:b'}), isEmpty);
      expect(await kept({'a': 1}, {'a': 'exclude_with:b'}), {'a': 1});
      expect(await kept({'a': 1}, {'a': 'exclude_without:b'}), isEmpty);
      expect(await kept({'a': 1, 'b': 'x'}, {'a': 'exclude_without:b'}), {
        'a': 1,
      });
    });

    test('exclude_if needs the other field to exist', () async {
      expect(await kept({'a': 1}, {'a': 'exclude_if:b,x'}), {'a': 1});
    });

    test('a later rule sees the attribute as gone', () async {
      final result = await errors(
        {'a': 'x'},
        {'a': 'exclude', 'b': 'required_with:a'},
      );
      expect(result, isEmpty);
    });

    test('nested attributes leave with their parent', () async {
      expect(
        await kept(
          {
            'a': {'b': 1},
            'c': 'x',
          },
          {'a': 'exclude', 'a.b': 'string', 'c': 'string'},
        ),
        {'c': 'x'},
      );
    });

    test('inside a list, the other items keep their place', () async {
      expect(
        await kept(
          {
            'items': [
              {'kind': 'a', 'qty': 1},
              {'kind': 'b', 'qty': 2},
            ],
          },
          {
            'items.*.kind': 'required',
            'items.*.qty': 'exclude_if:items.0.kind,a',
          },
        ),
        {
          'items': [
            {'kind': 'a'},
            {'kind': 'b'},
          ],
        },
      );
    });

    test('the input of the caller is not touched', () async {
      final data = <String, Object?>{'a': 1};
      await kept(data, {'a': 'exclude'});
      expect(data, {'a': 1});
    });
  });

  test('the Indonesian messages', () async {
    final result = await Validator(
      {'a': 1},
      const {'a': 'gt:3'},
      locale: 'id',
    ).run();
    expect(result['a'], ['Kolom a harus lebih besar dari 3.']);
  });

  group('Rules.enum_', () {
    test('the name, or the wire value', () async {
      Future<bool> check(Rule rule, Object value) async => (await errors(
        {'a': value},
        {
          'a': [rule],
        },
      )).isEmpty;
      expect(await check(Rules.enum_(Status.values), 'draft'), isTrue);
      expect(await check(Rules.enum_(Status.values), 'gone'), isFalse);
      final wire = Rules.enum_(Status.values, toValue: (s) => s.index);
      expect(await check(wire, 1), isTrue);
      expect(await check(wire, 'draft'), isFalse);
      final only = Rules.enum_(Status.values, only: [Status.draft]);
      expect(await check(only, 'published'), isFalse);
      final except = Rules.enum_(Status.values, except: [Status.draft]);
      expect(await check(except, 'draft'), isFalse);
    });
  });

  group('database rules', () {
    late Directory base;
    late Application app;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_rules');
      app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .create();
      await app.boot();
      await app.run(() async {
        await DB.statement(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, '
          'deleted_at TEXT, staff_id INTEGER)',
        );
        await DB.table('users').insert([
          {'id': 1, 'email': 'a@x.io', 'deleted_at': null, 'staff_id': 10},
          {'id': 2, 'email': 'b@x.io', 'deleted_at': '2026', 'staff_id': 20},
        ]);
      });
    });

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    Future<bool> valid(Object? value, Rule rule) => app.run(
      () async => (await Validator(
        {'email': value},
        {
          'email': [rule],
        },
        container: Container.current,
      ).run()).isEmpty,
    );

    test('unique ignore', () async {
      final rule = Rules.unique('users', 'email');
      expect(await valid('a@x.io', rule), isFalse);
      expect(await valid('a@x.io', rule.ignore(1)), isTrue);
      expect(await valid('a@x.io', rule.ignore(2)), isFalse);
      expect(
        await valid('a@x.io', rule.ignore(10, idColumn: 'staff_id')),
        isTrue,
      );
    });

    test('unique where', () async {
      final rule = Rules.unique(
        'users',
        'email',
      ).where((QueryBuilder q) => q.whereNull('deleted_at'));
      expect(await valid('b@x.io', rule), isTrue, reason: 'soft deleted');
      expect(await valid('a@x.io', rule), isFalse);
    });

    test('exists where', () async {
      final rule = Rules.exists(
        'users',
        'email',
      ).where((QueryBuilder q) => q.whereNull('deleted_at'));
      expect(await valid('a@x.io', rule), isTrue);
      expect(await valid('b@x.io', rule), isFalse);
    });

    test('a table cannot smuggle SQL through its name', () {
      expect(
        valid('a', Rules.unique('users; DROP TABLE users', 'email')),
        throwsArgumentError,
      );
    });
  });
}
