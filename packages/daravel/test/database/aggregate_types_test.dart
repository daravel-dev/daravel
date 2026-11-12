import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `count`, `sum`, `avg`, `min` and `max` on integer, bigint, decimal and
/// float columns, and on an empty table, on SQLite and (with
/// `DARAVEL_TEST_PG`) PostgreSQL. PostgreSQL returns `SUM` of a bigint or
/// decimal and every `AVG` as `numeric`, which the driver hands over as a
/// string; `sum` and `avg` read it by Laravel's `numericAggregate` rule.
/// The MySQL run of the same expectations is in `daravel_mysql`.
void main() {
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  final runs = <String, Map<String, String> Function()>{
    'SQLite': () => {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('aggregate_types_').path,
        'db.sqlite',
      ),
    },
    if (pg != null && pg.isNotEmpty)
      'PostgreSQL': () => {'DB_CONNECTION': 'pgsql', 'DB_URL': pg},
  };
  for (final MapEntry(key: name, value: env) in runs.entries) {
    group(name, () {
      late Application app;
      setUp(() async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({'APP_ENV': 'testing', ...env()})
            .withLogLevel(LogLevel.critical)
            .create();
        await app.boot();
        await app.run(() async {
          final schema = await Schema.builder();
          await schema.dropIfExists('aggregate_types');
          await schema.create('aggregate_types', (table) {
            table.id();
            table.integer('i').nullable();
            table.bigInteger('b').nullable();
            table.decimal('d', precision: 10, scale: 2).nullable();
            table.doublePrecision('f').nullable();
          });
        });
      });
      tearDown(() async {
        await app.run(
          () async => (await Schema.builder()).dropIfExists('aggregate_types'),
        );
        await app.shutdown();
      });

      test('on integer, bigint, decimal and float columns', () async {
        await app.run(() async {
          await DB.table('aggregate_types').insert([
            {'i': 1, 'b': 3000000000, 'd': 1.25, 'f': 0.5},
            {'i': 2, 'b': 3000000000, 'd': 2.5, 'f': 1.5},
            {'i': 4, 'b': 1, 'd': 0, 'f': 1},
          ]);
          QueryBuilder rows() => DB.table('aggregate_types');
          expect(await rows().count(), 3);
          expect(await rows().count('i'), 3);

          final sumI = await rows().sum('i');
          expect(sumI, 7);
          expect(sumI, isA<int>());
          final sumB = await rows().sum('b');
          expect(sumB, 6000000001);
          expect(sumB, isA<int>());
          expect(await rows().sum('d'), 3.75);
          expect(await rows().sum('f'), 3.0);

          expect(await rows().avg('i'), closeTo(7 / 3, 1e-9));
          expect(await rows().avg('b'), closeTo(6000000001 / 3, 1e-3));
          expect(await rows().avg('d'), closeTo(1.25, 1e-9));
          expect(await rows().avg('f'), closeTo(1.0, 1e-9));

          // min and max hand over the driver's value as Laravel does: a
          // decimal is a string on PostgreSQL, a number on SQLite.
          num asNumber(Object? value) => num.parse('$value');
          expect(asNumber(await rows().min('i')), 1);
          expect(asNumber(await rows().max('b')), 3000000000);
          expect(asNumber(await rows().min('d')), 0);
          expect(asNumber(await rows().max('d')), 2.5);
          expect(asNumber(await rows().max('f')), 1.5);
        });
      });

      test(
        'on an empty table: sum, avg, min and max null (1.x: sum stays null)',
        () async {
          await app.run(() async {
            QueryBuilder rows() => DB.table('aggregate_types');
            expect(await rows().count(), 0);
            expect(await rows().sum('i'), isNull);
            expect(await rows().sum('d'), isNull);
            expect(await rows().avg('i'), isNull);
            expect(await rows().avg('d'), isNull);
            expect(await rows().min('i'), isNull);
            expect(await rows().max('d'), isNull);
          });
        },
      );

      test('only nulls: sum and avg null (1.x)', () async {
        await app.run(() async {
          await DB.table('aggregate_types').insert({'i': null});
          QueryBuilder rows() => DB.table('aggregate_types');
          expect(await rows().count(), 1);
          expect(await rows().count('i'), 0);
          expect(await rows().sum('i'), isNull);
          expect(await rows().avg('i'), isNull);
        });
      });
    });
  }
}
