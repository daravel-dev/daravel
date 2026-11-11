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
}
