import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

/// LK-1: the database cache store's "insert, else take over" (`acquireLock`
/// and `add`) reads only a unique violation as "taken", runs the insert in a
/// savepoint inside a transaction (PostgreSQL aborts the whole transaction
/// on a failed statement), refuses keys longer than the column instead of
/// reporting them as taken or cutting them (MySQL's `INSERT IGNORE` in
/// `increment`), and deletes an expired row only while it is still expired.
void cacheLockInsertTests(DatabaseOpener open) {
  late DatabaseManager db;
  late DatabaseStore store;

  // Tables of its own: other test files use `cache` on the same server
  // database at the same time. The columns are CreateCacheTable's.
  const cache = 'lk1_cache';
  const locks = 'lk1_cache_locks';
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

  test('a held lock taken again inside a transaction answers false and '
      'leaves the transaction usable', () async {
    expect(
      await store.acquireLock('job', 'a', const Duration(minutes: 1)),
      isTrue,
    );
    await db.transaction(() async {
      expect(
        await store.acquireLock('job', 'b', const Duration(minutes: 1)),
        isFalse,
      );
      expect(
        await store.add('key', 1, ttl: const Duration(minutes: 1)),
        isTrue,
      );
      expect(
        await store.add('key', 2, ttl: const Duration(minutes: 1)),
        isFalse,
      );
      // The transaction still runs statements (PostgreSQL: not 25P02).
      expect(await db.table(cache).count(), 1);
    });
    expect(await store.lockOwner('job'), 'a');
    expect(await store.get('key'), 1, reason: 'committed');
  });

  test('a key longer than the column is refused, not reported as taken '
      'or cut', () async {
    final long = 'k' * 300;
    await expectLater(
      store.acquireLock(long, 'a', const Duration(minutes: 1)),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      store.add(long, 1, ttl: const Duration(minutes: 1)),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(store.increment(long), throwsA(isA<ArgumentError>()));
    expect(await db.table(cache).count(), 0, reason: 'nothing cut and kept');
    expect(await db.table(locks).count(), 0);
    final fits = 'k' * 255;
    expect(
      await store.acquireLock(fits, 'a', const Duration(minutes: 1)),
      isTrue,
    );
    expect(await store.increment(fits), 1);
  });

  test('an error other than a unique violation is thrown, not read as '
      'taken', () async {
    final missing = DatabaseStore(
      db,
      table: 'no_such_cache',
      lockTable: 'no_such_locks',
      pruneLottery: (0, 1),
    );
    await expectLater(
      missing.acquireLock('job', 'a', const Duration(minutes: 1)),
      throwsA(isA<QueryException>()),
    );
    await expectLater(
      missing.add('key', 1, ttl: const Duration(minutes: 1)),
      throwsA(isA<QueryException>()),
    );
  });

  test('an expired row is deleted only while it is still expired', () async {
    await db.table(cache).insert({
      'key': 'old',
      'value': '{"v":1}',
      'expiration': 1,
    });
    final (value, queries) = await db.captureQueries(() => store.get('old'));
    expect(value, isNull);
    final deletes = [
      for (final query in queries)
        if (query.sql.toUpperCase().startsWith('DELETE')) query,
    ];
    expect(deletes, hasLength(1));
    expect(
      deletes.single.sql,
      contains('expiration'),
      reason: 'a value written meanwhile under the key is kept',
    );
    expect(await db.table(cache).count(), 0);
  });
}

void main() {
  forEachDatabase(cacheLockInsertTests);
}
