import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String appKey = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Wins every session lottery.
final class _AlwaysWin implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 0;
}

/// The `database` driver's sweep runs in the request that wins the
/// lottery, so under `refreshDatabase` its `DELETE` stays in the test's
/// transaction: a row committed before the tests survives them, and the
/// sweep never waits for the test's row locks (run detached, it deleted
/// such a row on PostgreSQL and MySQL, and waited on MySQL until the test
/// rolled back; #388). SQLite, and PostgreSQL with `DARAVEL_TEST_PG`.
void main() {
  final pg = Platform.environment['DARAVEL_TEST_PG'];

  Application build(Map<String, String> env) =>
      Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_KEY': appKey,
            'SESSION_DRIVER': 'database',
            'DB_POOL_SIZE': '2',
            ...env,
          })
          .withLogLevel(LogLevel.critical)
          .withSession()
          .withMigrations(const [CreateSessionsTable()])
          .withMiddleware(
            (m) => m.alias(
              'session_gc',
              StartSessionMiddleware(lottery: _AlwaysWin()),
            ),
          )
          .withRouting(
            web: (router) => router.get('/', (request) {
              request.session.put('name', 'Jane');
              return {'ok': true};
            })..middleware(const ['session_gc']),
          )
          .create();

  final runs = <String, Application Function()>{
    'SQLite': () => build({
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('session_gc_refresh_').path,
        'db.sqlite',
      ),
    }),
    if (pg != null && pg.isNotEmpty)
      'PostgreSQL': () => build({'DB_CONNECTION': 'pgsql', 'DB_URL': pg}),
  };

  const committed = 'committed-expired-row-000000000000000000';

  for (final MapEntry(key: name, value: create) in runs.entries) {
    group(name, () {
      final db = refreshDatabase(create);

      setUpAll(() async {
        await db.app.run(() async {
          await DB.table('sessions').delete();
          await DB.table('sessions').insert({
            'id': committed,
            'payload': '',
            'last_activity': 0,
          });
        });
      });

      tearDownAll(() async {
        await db.app.run(() => DB.table('sessions').delete());
      });

      db.test('the winning request sweeps in its transaction', () async {
        final watch = Stopwatch()..start();
        (await db.client.get('/')).assertOk();
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          db.app.container.make<SessionManager>().garbageCollector.running,
          isNull,
          reason: 'not detached',
        );
        expect(
          await DB.table('sessions').where('id', committed).exists(),
          isFalse,
          reason: 'swept inside the test',
        );
      });

      db.test('a row committed before the tests survives them', () async {
        expect(
          await DB.table('sessions').where('id', committed).exists(),
          isTrue,
        );
      });
    });
  }
}
