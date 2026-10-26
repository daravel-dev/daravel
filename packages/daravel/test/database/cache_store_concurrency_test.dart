import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

void main() {
  forEachDatabase(cacheStoreConcurrencyTests);
  // A database file shared by two pools, as worker isolates share it.
  group('sqlite file', () {
    late Directory dir;
    setUpAll(() => dir = Directory.systemTemp.createTempSync('daravel_cas'));
    tearDownAll(() => dir.deleteSync(recursive: true));
    cacheStoreConcurrencyTests(
      () => DatabaseManager(
        DatabaseConfig(
          defaultConnection: 'sqlite',
          connections: {
            'sqlite': ConnectionConfig(
              driver: 'sqlite',
              database: '${dir.path}/cache.sqlite',
            ),
          },
        ),
      ),
    );
  });
}

/// The database cache store shared by several machines (two pools here):
/// counters and the rate limits built on them must not lose updates. Also
/// run on MySQL and MariaDB by daravel_mysql/test/orm_matrix_test.dart.
void cacheStoreConcurrencyTests(DatabaseOpener open) {
  late DatabaseManager first;
  late DatabaseManager second;

  setUp(() async {
    first = open();
    second = open();
    final schema = await freshSchema(first, ['cache', 'cache_locks']);
    await const CreateCacheTable().up(schema);
  });
  tearDown(() async {
    await first.closeAll();
    await second.closeAll();
  });

  test('touch changes the expiration, not the value', () async {
    // A frozen clock: expirations are whole seconds, so a real one could
    // tick past a short TTL between put and touch.
    Clock.freeze();
    addTearDown(Clock.restore);
    final store = DatabaseStore(first);
    await store.put('hits', 4, ttl: const Duration(minutes: 1));
    expect(await store.touch('hits', const Duration(hours: 1)), isTrue);
    // Past the original TTL: only the touched expiration keeps it.
    Clock.travel(const Duration(minutes: 2));
    expect(await store.get('hits'), 4);
    expect(await store.touch('missing', const Duration(hours: 1)), isFalse);
  });

  test('concurrent increments from two machines are all counted', () async {
    if (first.dialectOf() == SqlDialect.sqlite &&
        first.config.connections.values.first.database == ':memory:') {
      markTestSkipped('Two pools cannot share one in-memory SQLite database.');
      return;
    }
    final a = DatabaseStore(first);
    final b = DatabaseStore(second);
    await a.put('hits', 0, ttl: const Duration(minutes: 1));
    await Future.wait([
      for (var i = 0; i < 20; i++) ...[
        a.increment('hits'),
        b.increment('hits'),
      ],
    ]);
    expect(await a.get('hits'), 40);
  });

  test('a shared rate limit never lets more through than its limit', () async {
    if (first.dialectOf() == SqlDialect.sqlite &&
        first.config.connections.values.first.database == ':memory:') {
      markTestSkipped('Two pools cannot share one in-memory SQLite database.');
      return;
    }
    final a = CacheRateLimitStore(() => DatabaseStore(first));
    final b = CacheRateLimitStore(() => DatabaseStore(second));
    const window = Duration(minutes: 1);
    final results = await Future.wait([
      for (var i = 0; i < 15; i++) ...[
        a.attempt('login', 10, window),
        b.attempt('login', 10, window),
      ],
    ]);
    expect(results.where((r) => r.allowed), hasLength(10));
    expect(await a.attempts('login', window), 10);
  });
}
