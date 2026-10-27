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
    now = now.add(const Duration(seconds: 2));
    expect(
      await store.acquireLock('order:5', 'w', const Duration(seconds: 1)),
      isTrue,
    );
    expect(store.lockCount, 1, reason: 'the five expired ones are gone');
    expect(await store.lockOwner('order:5'), 'w');
    // Re-acquiring an expired lock by name never sweeps (it is replaced).
    expect(
      await store.acquireLock('order:5', 'other', const Duration(seconds: 1)),
      isFalse,
    );
  });
}
