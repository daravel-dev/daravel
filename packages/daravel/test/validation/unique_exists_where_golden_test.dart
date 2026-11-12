import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `unique` and `exists` with `column,value` where conditions in the string
/// form, against Laravel itself: `fixtures/laravel_unique_exists_where.json`
/// holds a table, its rows and each (rule, value) as Laravel 13.40.0 / PHP
/// 8.3 validated it over SQLite (the interop image, without network).
/// Daravel builds the same table and must report the same errors, and
/// refuse where Laravel throws (an odd number of condition arguments).
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_unique_exists_where.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();
  late Directory base;
  late Application app;

  setUpAll(() async {
    base = Directory.systemTemp.createTempSync('daravel_where_golden');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    await app.run(() async {
      await DB.statement(golden['schema']! as String);
      await DB.table('users').insert([
        for (final row in golden['rows']! as List<Object?>)
          (row! as Map<String, Object?>),
      ]);
      await DB.statement(golden['accounts']! as String);
      await DB.table('accounts').insert([
        for (final row in golden['accountRows']! as List<Object?>)
          (row! as Map<String, Object?>),
      ]);
    });
  });

  tearDownAll(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(50)));
  });

  for (final c in cases) {
    final rule = c['rule']! as String;
    final value = c['value'];
    test('$rule with $value', () async {
      Future<Map<String, List<String>>> run() => app.run(
        () => Validator(
          {'email': value},
          {'email': rule},
          container: Container.current,
        ).run(),
      );
      if (c.containsKey('throws')) {
        await expectLater(run, throwsArgumentError);
        return;
      }
      final expected = switch (c['errors']) {
        final Map<String, Object?> map => {
          for (final MapEntry(:key, value: list) in map.entries)
            key: (list! as List<Object?>).cast<String>(),
        },
        _ => <String, List<String>>{},
      };
      expect(await run(), expected);
    });
  }

  // The key `unique` skips, as Laravel's prepareUniqueId reads it: from
  // the input (`[id]`, `[user.id]`), `null` in any case, an integer with
  // whitespace or a sign, text such as `01` or `1abc`, a backslash, a
  // custom key column and a uuid key.
  for (final c
      in (golden['ignoreCases']! as List<Object?>)
          .cast<Map<String, Object?>>()) {
    final rule = c['rule']! as String;
    final data = (c['data']! as Map<String, Object?>);
    test('ignore: $rule with $data', () async {
      final expected = switch (c['errors']) {
        final Map<String, Object?> map => {
          for (final MapEntry(:key, value: list) in map.entries)
            key: (list! as List<Object?>).cast<String>(),
        },
        _ => <String, List<String>>{},
      };
      final errors = await app.run(
        () => Validator(data, {
          'email': rule,
        }, container: Container.current).run(),
      );
      expect(errors, expected);
    });
  }

  // exists on a list of values (Laravel's getMultiCount: whereIn and a
  // distinct count), with and without where conditions; values sent as
  // lists, maps and booleans to exists and unique.
  //
  // Where Daravel parts from Laravel on purpose: an exists list holding a
  // list or a map fails the rule. Laravel throws for it (ErrorException
  // from array_unique, a 500) or, with one nested element, accepts it
  // because whereIn flattens it.
  bool nested(Object? value) => switch (value) {
    final List<Object?> list => list.any(
      (v) => v is List<Object?> || v is Map<Object?, Object?>,
    ),
    final Map<Object?, Object?> map => map.values.any(
      (v) => v is List<Object?> || v is Map<Object?, Object?>,
    ),
    _ => false,
  };
  for (final c
      in (golden['arrayCases']! as List<Object?>)
          .cast<Map<String, Object?>>()) {
    final rule = c['rule']! as String;
    final data = (c['data']! as Map<String, Object?>);
    final field = data.keys.first;
    final departs = rule.startsWith('exists:') && nested(data[field]);
    test(
      'array: $rule with $data${departs ? ' (fails, unlike Laravel)' : ''}',
      () async {
        final expected = departs
            ? {
                field: ['The selected $field is invalid.'],
              }
            : switch (c['errors']) {
                final Map<String, Object?> map => {
                  for (final MapEntry(:key, value: list) in map.entries)
                    key: (list! as List<Object?>).cast<String>(),
                },
                _ => <String, List<String>>{},
              };
        if (c.containsKey('throws')) {
          expect(
            departs,
            isTrue,
            reason:
                'Laravel throws (${c['throws']}) only where Daravel departs',
          );
        }
        final errors = await app.run(
          () => Validator(data, {
            data.keys.first: rule,
          }, container: Container.current).run(),
        );
        expect(errors, expected);
      },
    );
  }

  // A list longer than the placeholders a driver takes (SQLite 32 766)
  // made a database error, a 500, in Laravel and here. Above
  // ExistsRule.maxListValues distinct values the rule fails without a
  // query; up to it, one query.
  group('exists on a long list', () {
    const rows = ExistsRule.maxListValues + 1;
    setUpAll(() async {
      await app.run(() async {
        await DB.statement('CREATE TABLE many (id INTEGER PRIMARY KEY)');
        for (var start = 1; start <= rows; start += 500) {
          await DB.table('many').insert([
            for (var id = start; id < start + 500 && id <= rows; id++)
              {'id': id},
          ]);
        }
      });
    });

    Future<Map<String, List<String>>> check(List<Object?> ids) => app.run(
      () => Validator(
        {'ids': ids},
        {'ids': 'exists:many,id'},
        container: Container.current,
      ).run(),
    );

    test('up to the limit: one query, every value found', () async {
      expect(
        await check([
          for (var id = 1; id <= ExistsRule.maxListValues; id++) id,
        ]),
        isEmpty,
      );
    });

    test('above it: fails, though every value is in the table', () async {
      expect(await check([for (var id = 1; id <= rows; id++) id]), {
        'ids': ['The selected ids is invalid.'],
      });
    });

    test(
      'far above what a driver binds: fails, not a database error',
      () async {
        expect(await check([for (var id = 1; id <= 40000; id++) id]), {
          'ids': ['The selected ids is invalid.'],
        });
      },
    );

    test('repeated values count once', () async {
      expect(
        await check([for (var i = 0; i < 40000; i++) (i % 5) + 1]),
        isEmpty,
      );
    });
  });
}
