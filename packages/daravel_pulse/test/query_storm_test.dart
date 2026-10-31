import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_pulse/daravel_pulse.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  group('fingerprint', () {
    test('one statement whatever its bindings or placeholders', () {
      expect(
        QueryTally.fingerprint(r'SELECT * FROM a WHERE id = $1'),
        QueryTally.fingerprint('SELECT * FROM a WHERE id = ?'),
      );
    });

    test('an IN of any length', () {
      expect(
        QueryTally.fingerprint(r'SELECT * FROM a WHERE id IN ($1, $2, $3)'),
        QueryTally.fingerprint('SELECT * FROM a WHERE id IN (?, ?)'),
      );
    });

    test('other statements stay apart', () {
      expect(
        QueryTally.fingerprint('SELECT * FROM a WHERE id = ?'),
        isNot(QueryTally.fingerprint('SELECT * FROM b WHERE id = ?')),
      );
    });
  });

  group('per request', () {
    late Directory base;
    late Application app;
    late TestClient client;
    late PulseRecorder recorder;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_storm');
      app = Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'PULSE_N_PLUS_ONE_THRESHOLD': '5',
            'PULSE_QUERY_STORM_THRESHOLD': '10',
          })
          .withLogLevel(LogLevel.critical)
          .withPulse()
          .withRouting(
            web: (router) {
              Future<Object?> repeat(int count) async {
                for (var i = 0; i < count; i++) {
                  await DB.table('rows').where('id', i).first();
                }
                return 'ok';
              }

              router.get('/many', (_) => repeat(6));
              router.get('/few', (_) => repeat(4));
              router.get('/in-tx', (_) => DB.transaction(() => repeat(6)));
              router.get('/varied', (_) async {
                for (var i = 0; i < 11; i++) {
                  await DB.select('SELECT $i FROM rows');
                }
                return 'ok';
              });
            },
          )
          .create();
      await app.boot();
      await app.run(
        () => DB.statement('CREATE TABLE rows (id INTEGER PRIMARY KEY)'),
      );
      recorder = app.container.make<PulseRecorder>();
      client = TestClient(app);
    });

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    List<Map<String, Object?>> storms() {
      final snapshot = PulseSnapshot.build(
        [recorder.report()],
        window: const Duration(hours: 1),
        now: Clock.now(),
      );
      return (snapshot['query_storms']! as List<Object?>)
          .cast<Map<String, Object?>>();
    }

    test('a statement repeated past the threshold is listed', () async {
      await client.get('/many');
      final storm = storms().single;
      expect(storm['route'], '/many');
      expect(storm['repeats'], 6);
      expect(storm['sql'], contains('FROM "rows"'));
    });

    test('below it, nothing is', () async {
      await client.get('/few');
      expect(storms(), isEmpty);
    });

    test('queries in a transaction count', () async {
      await client.get('/in-tx');
      expect(storms().single['route'], '/in-tx');
    });

    test('many different queries are a storm too', () async {
      await client.get('/varied');
      final storm = storms().single;
      expect(storm['queries'], 11);
    });

    test('requests are counted apart', () async {
      await client.get('/few');
      await client.get('/few');
      expect(storms(), isEmpty, reason: 'four each, not eight');
    });
  });

  test('a pool wait is listed by connection', () {
    final recorder = PulseRecorder()
      ..recordPoolWait('pgsql', const Duration(milliseconds: 40))
      ..recordPoolWait('pgsql', const Duration(milliseconds: 90));
    final snapshot = PulseSnapshot.build(
      [recorder.report()],
      window: const Duration(hours: 1),
      now: Clock.now(),
    );
    final wait = (snapshot['pool_waits']! as List<Object?>).single;
    expect(wait, containsPair('connection', 'pgsql'));
    expect(wait, containsPair('count', 2));
    expect(wait, containsPair('max_ms', 90.0));
  });
}
