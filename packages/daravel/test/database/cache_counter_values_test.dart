import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

/// LK-1 item 5: the database store leaves a value it cannot count alone
/// (Laravel's `DatabaseStore` answers false there), and the rate limiter
/// reports a counter the database cannot convert once per key, failing open
/// as for any store error, while other errors are reported every time.
void cacheCounterValueTests(DatabaseOpener open) {
  late DatabaseManager db;
  late DatabaseStore store;
  // Tables of its own: other test files use `cache` at the same time.
  const cache = 'lk5_cache';
  const locks = 'lk5_cache_locks';

  setUp(() async {
    db = open();
    final schema = await freshSchema(db, [cache, locks]);
    await schema.create(cache, (table) {
      table.string('key').primary();
      table.mediumText('value');
      table.integer('expiration').index();
    });
    await schema.create(locks, (table) {
      table.string('key').primary();
      table.string('owner');
      table.integer('expiration').index();
    });
    store = DatabaseStore(
      db,
      table: cache,
      lockTable: locks,
      pruneLottery: (0, 1),
    );
  });
  tearDown(() => db.closeAll());

  Future<Object?> raw(String key) async =>
      (await db.table(cache).where('key', key).first())?['value'];

  test(
    'increment of a value that is not a number leaves it and throws',
    () async {
      // Laravel's serialize() of 5, a Daravel string, a Daravel null.
      final values = {
        'laravel': 'i:5;',
        'text': '{"v":"abc"}',
        'null': '{"v":null}',
        // Not whole decimal numbers that fit (none may surface as anything
        // but a StateError, nor be read as another number).
        'nan': '{"v":"NaN"}',
        'infinity': '{"v":"Infinity"}',
        'huge': '{"v":"1e309"}',
        'hex': '{"v":"0x10"}',
        'fraction': '{"v":"3.7"}',
        'exponent': '{"v":"1e3"}',
        'overflow': '{"v":"99999999999999999999"}',
        'double': '{"v":3.7}',
      };
      for (final MapEntry(:key, :value) in values.entries) {
        await db.table(cache).insert({
          'key': key,
          'value': value,
          'expiration': DatabaseStore.foreverExpiration,
        });
        await expectLater(store.increment(key), throwsA(isA<StateError>()));
        await expectLater(store.decrement(key), throwsA(isA<StateError>()));
        expect(await raw(key), value, reason: 'left as it was');
      }
      await store.put('number', 4);
      expect(await store.increment('number', 2), 6);
      await store.put('digits', '7');
      expect(await store.increment('digits'), 8, reason: 'decimal digits');
      await store.put('whole', 3.0);
      expect(await store.increment('whole'), 4, reason: 'a whole double');
      expect(await store.increment('fresh'), 1);
    },
  );

  test('a rate limit counter the database cannot convert is reported once '
      'per key and fails open; other errors every time', () async {
    final errors = <Object>[];
    final limiter = CacheRateLimitStore(() => store, onError: errors.add);
    await db.table(cache).insert({
      'key': 'rate_limiter:login:window',
      'value': '{"v":"not digits"}',
      'expiration': DatabaseStore.foreverExpiration,
    });
    final dialect = (await db.executor()).dialect;
    for (var i = 0; i < 3; i++) {
      final result = await limiter.attempt(
        'login',
        5,
        const Duration(minutes: 1),
      );
      expect(result.allowed, isTrue);
    }
    if (dialect == SqlDialect.sqlite) {
      // SQLite casts text that is not a number to 0: no error, the counter
      // starts over.
      expect(errors, isEmpty);
    } else {
      expect(errors, hasLength(1), reason: 'once for the key');
    }

    errors.clear();
    final missing = DatabaseStore(
      db,
      table: 'lk5_no_such_table',
      lockTable: locks,
      pruneLottery: (0, 1),
    );
    final broken = CacheRateLimitStore(() => missing, onError: errors.add);
    for (var i = 0; i < 3; i++) {
      final result = await broken.attempt(
        'login',
        5,
        const Duration(minutes: 1),
      );
      expect(result.allowed, isTrue);
      expect(result.degraded, isTrue);
    }
    expect(errors, hasLength(3), reason: 'not a conversion: every time');
  });

  test('a key too long for the column is reported every time; a counter '
      'that was repaired and broke again is reported again', () async {
    final errors = <Object>[];
    final limiter = CacheRateLimitStore(() => store, onError: errors.add);
    final dialect = (await db.executor()).dialect;
    final long = 'k' * 300;
    for (var i = 0; i < 3; i++) {
      await limiter.attempt(long, 5, const Duration(minutes: 1));
    }
    if (dialect == SqlDialect.sqlite) {
      expect(errors, isEmpty, reason: 'SQLite stores any length');
    } else {
      expect(errors, hasLength(3), reason: 'too long: not a counter value');
    }

    errors.clear();
    Future<void> breakCounter() => db.table(cache).insert({
      'key': 'rate_limiter:login:window',
      'value': '{"v":"not digits"}',
      'expiration': DatabaseStore.foreverExpiration,
    });
    await breakCounter();
    await limiter.attempt('login', 5, const Duration(minutes: 1));
    await limiter.attempt('login', 5, const Duration(minutes: 1));
    await db.table(cache).where('key', 'rate_limiter:login:window').delete();
    await limiter.attempt('login', 5, const Duration(minutes: 1));
    await db.table(cache).where('key', 'rate_limiter:login:window').delete();
    await breakCounter();
    await limiter.attempt('login', 5, const Duration(minutes: 1));
    await limiter.clear('login');
    await breakCounter();
    await limiter.attempt('login', 5, const Duration(minutes: 1));
    if (dialect != SqlDialect.sqlite) {
      expect(
        errors,
        hasLength(3),
        reason: 'once per breakage: after a count that worked, after clear',
      );
    }
  });
}

void main() {
  forEachDatabase(cacheCounterValueTests);
}
