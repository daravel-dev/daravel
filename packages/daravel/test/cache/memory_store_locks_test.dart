import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Expired locks that were never released (their holder crashed) used to
/// stay in the memory store for ever; with one lock name per order or user
/// the map only grew.
void main() {
  test('expired locks are swept once there are maxEntries of them', () async {
    var now = DateTime.utc(2026, 10, 28);
    final store = MemoryStore(maxEntries: 4, clock: () => now);
    for (var i = 0; i < 4; i++) {
      expect(
        await store.acquireLock('order:$i', 'w', const Duration(seconds: 1)),
        isTrue,
      );
    }
    expect(store.lockCount, 4);
    // Still held: a new name does not evict a live lock.
    expect(
      await store.acquireLock('order:4', 'w', const Duration(seconds: 1)),
      isTrue,
    );
    expect(store.lockCount, 5);
    expect(store.lockSweeps, 1);
    now = now.add(const Duration(seconds: 2));
    // The sweep found every lock live: the next one waits until the map
    // doubled (8), then removes the expired ones.
    for (var i = 5; i < 8; i++) {
      expect(
        await store.acquireLock('order:$i', 'w', const Duration(seconds: 1)),
        isTrue,
      );
    }
    expect(store.lockCount, 8);
    expect(
      await store.acquireLock('order:8', 'w', const Duration(seconds: 1)),
      isTrue,
    );
    expect(store.lockSweeps, 2);
    expect(store.lockCount, 4, reason: 'the five expired ones are gone');
    expect(await store.lockOwner('order:8'), 'w');
    // Re-acquiring an expired lock by name never sweeps (it is replaced).
    expect(
      await store.acquireLock('order:8', 'other', const Duration(seconds: 1)),
      isFalse,
    );
  });

  test('with many live locks, new names do not sweep on every acquire '
      '(#167)', () async {
    final now = DateTime.utc(2026, 10, 28);
    final store = MemoryStore(maxEntries: 100, clock: () => now);
    for (var i = 0; i < 10000; i++) {
      await store.acquireLock('user:$i', 'w', const Duration(hours: 1));
    }
    expect(store.lockCount, 10000);
    // Doubling thresholds: 100, 200, 400, ... 6400.
    expect(store.lockSweeps, lessThanOrEqualTo(8));
  });

  test('flush keeps the locks; flushLocks and pruneExpired remove them '
      '(#167)', () async {
    var now = DateTime.utc(2026, 10, 28);
    final store = MemoryStore(clock: () => now);
    await store.put('k', 1);
    expect(
      await store.acquireLock('report', 'a', const Duration(minutes: 1)),
      isTrue,
    );
    expect(
      await store.acquireLock('stale', 'a', const Duration(seconds: 1)),
      isTrue,
    );
    await store.flush();
    expect(await store.get('k'), isNull);
    expect(await store.lockOwner('report'), 'a');
    expect(
      await store.acquireLock('report', 'b', const Duration(minutes: 1)),
      isFalse,
      reason: 'a flush must not hand a held lock to a second holder',
    );

    await store.put('short', 1, ttl: const Duration(seconds: 1));
    await store.put('long', 1, ttl: const Duration(hours: 1));
    now = now.add(const Duration(seconds: 2));
    expect(await store.pruneExpired(), 2); // `short` and the `stale` lock
    expect(store.size, 1);
    expect(store.lockCount, 1);

    await store.flushLocks();
    expect(await store.lockOwner('report'), isNull);
    expect(await store.get('long'), 1);
  });

  test('at capacity, expired entries are evicted before live ones '
      '(#167)', () async {
    var now = DateTime.utc(2026, 10, 28);
    final store = MemoryStore(maxEntries: 4, clock: () => now);
    await store.put('live-1', 1);
    await store.put('short-1', 1, ttl: const Duration(seconds: 1));
    await store.put('short-2', 1, ttl: const Duration(seconds: 1));
    await store.put('live-2', 1);
    now = now.add(const Duration(seconds: 2));
    await store.put('new', 1);
    // The least recently used live entry stays: the expired ones made room.
    expect(await store.get('live-1'), 1);
    expect(await store.get('live-2'), 1);
    expect(await store.get('new'), 1);
    expect(store.size, 3);
  });

  test('MemoryRateLimitStore evicts windows that are over before live '
      'ones (#167)', () async {
    var now = DateTime.utc(2026, 10, 28);
    final store = MemoryRateLimitStore(clock: () => now, maxKeys: 4);
    store.attemptSync('live', 10, const Duration(hours: 1));
    store.attemptSync('short-1', 10, const Duration(seconds: 1));
    store.attemptSync('short-2', 10, const Duration(seconds: 1));
    store.attemptSync('more', 10, const Duration(hours: 1));
    now = now.add(const Duration(seconds: 2));
    store.attemptSync('new', 10, const Duration(hours: 1));
    expect(store.attemptsSync('live', const Duration(hours: 1)), 1);
    expect(store.attemptsSync('more', const Duration(hours: 1)), 1);
    expect(store.size, 3);
  });
}
