import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// The MySQL (and MariaDB) run of `daravel`'s
/// `test/database/aggregate_types_test.dart`: MySQL returns `SUM` of an
/// integer or decimal and every `AVG` as `DECIMAL`, which the driver hands
/// over as a string. Runs only with `DARAVEL_TEST_MYSQL`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  group('MySQL', () {
    late Application app;
    setUp(() async {
      final uri = Uri.parse(url!);
      final user = uri.userInfo.split(':');
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'mysql',
            'DB_HOST': uri.host,
            'DB_PORT': '${uri.port}',
            'DB_DATABASE': uri.path.replaceFirst('/', ''),
            'DB_USERNAME': user.first,
            'DB_PASSWORD': user.length > 1 ? user[1] : '',
          })
          .withLogLevel(LogLevel.critical)
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
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

        // MySQL's AVG of an integer is a DECIMAL with
        // div_precision_increment (4) more places: '2.3333', as Laravel
        // receives it too.
        expect(await rows().avg('i'), closeTo(7 / 3, 1e-4));
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

    test('on an empty table: sum 0, avg, min and max null', () async {
      await app.run(() async {
        QueryBuilder rows() => DB.table('aggregate_types');
        expect(await rows().count(), 0);
        expect(await rows().sum('i'), 0);
        expect(await rows().sum('d'), 0);
        expect(await rows().avg('i'), isNull);
        expect(await rows().avg('d'), isNull);
        expect(await rows().min('i'), isNull);
        expect(await rows().max('d'), isNull);
      });
    });

    test('only nulls: sum 0, avg null', () async {
      await app.run(() async {
        await DB.table('aggregate_types').insert({'i': null});
        QueryBuilder rows() => DB.table('aggregate_types');
        expect(await rows().count(), 1);
        expect(await rows().count('i'), 0);
        expect(await rows().sum('i'), 0);
        expect(await rows().avg('i'), isNull);
      });
    });
  }, skip: url == null || url.isEmpty ? 'needs DARAVEL_TEST_MYSQL' : false);
}
