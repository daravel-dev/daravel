import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `DB.listen` (Laravel's `DB::listen`): every query of the builder, raw
/// SQL, schema and transactions reaches the listeners.
void main() {
  late Application app;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
  });
  tearDown(() => app.shutdown());

  test('reports SQL, bindings, duration and connection', () async {
    await app.run(() async {
      final events = <QueryExecuted>[];
      await Schema.create('posts', (t) {
        t.id();
        t.string('title');
      });
      DB.listen(events.add);

      await DB.table('posts').insert({'title': 'Hello'});
      await DB.table('posts').where('title', 'Hello').get();
      await DB.select('SELECT count(*) AS n FROM posts');
      await DB.transaction(() async {
        await DB.table('posts').insert({'title': 'In tx'});
      });

      final sql = events.map((e) => e.sql).toList();
      expect(sql.where((s) => s.startsWith('INSERT')), hasLength(2));
      expect(sql.where((s) => s.startsWith('SELECT')), hasLength(2));
      final where = events.firstWhere((e) => e.sql.contains('WHERE'));
      expect(where.bindings, ['Hello']);
      expect(where.connectionName, 'sqlite');
      expect(where.time, isA<Duration>());
    });
  });

  test('no listeners, no wrapping', () async {
    await app.run(() async {
      // Errors are always translated; listening wraps only with listeners.
      Future<QueryExecutor> inner() async =>
          ((await App.make<DatabaseManager>().executor())
                  as QueryExceptionExecutor)
              .inner;
      expect(await inner(), isNot(isA<ListeningQueryExecutor>()));
      DB.listen((_) {});
      expect(await inner(), isA<ListeningQueryExecutor>());
      App.make<DatabaseManager>().forgetListeners();
    });
  });
}
