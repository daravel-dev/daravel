import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Forces the interleaving that let a shared limit through one request too
/// many (seen on MariaDB in CI): A adds the counter, B finds it and
/// increments to 1, A increments to 2, then B "repairs" the counter it
/// thinks expired. Laravel's RateLimiter::hit() resets it to 1 there,
/// losing A's hit; a TouchableCacheStore only gives it a lifetime.
class _Scripted implements CacheStore {
  _Scripted(this.inner);

  final CacheStore inner;
  final Completer<void> bIncremented = Completer<void>();
  final Completer<void> aIncremented = Completer<void>();
  int _increments = 0;

  @override
  Future<int> increment(String key, [int by = 1]) async {
    if (_increments++ == 0) {
      // A: wait until B has incremented first.
      await bIncremented.future;
      final value = await inner.increment(key, by);
      aIncremented.complete();
      return value;
    }
    final value = await inner.increment(key, by);
    bIncremented.complete();
    return value;
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async {
    if (!key.endsWith(':timer')) {
      await aIncremented.future;
    }
    return inner.put(key, value, ttl: ttl);
  }

  @override
  Future<Object?> get(String key) => inner.get(key);
  @override
  Future<Map<String, Object?>> many(List<String> keys) => inner.many(keys);
  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      inner.add(key, value, ttl: ttl);
  @override
  Future<int> decrement(String key, [int by = 1]) => inner.decrement(key, by);
  @override
  Future<void> forever(String key, Object? value) => inner.forever(key, value);
  @override
  Future<bool> forget(String key) => inner.forget(key);
  @override
  Future<void> flush() => inner.flush();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ScriptedTouchable extends _Scripted
    implements TouchableCacheStore {
  _ScriptedTouchable(TouchableCacheStore super.inner);

  @override
  Future<bool> touch(String key, Duration ttl) async {
    await aIncremented.future;
    return (inner as TouchableCacheStore).touch(key, ttl);
  }
}

void main() {
  const window = Duration(minutes: 1);

  test(
    'a touchable store keeps both hits when the counter is repaired',
    () async {
      final store = _ScriptedTouchable(MemoryStore());
      final limiter = CacheRateLimitStore(() => store);
      final [a, b] = await Future.wait([
        limiter.attempt('login', 10, window),
        limiter.attempt('login', 10, window),
      ]);
      expect([a.allowed, b.allowed], [true, true]);
      expect(await limiter.attempts('login', window), 2);
    },
  );

  test("other stores keep Laravel's reset, which can lose that hit", () async {
    final store = _Scripted(MemoryStore());
    final limiter = CacheRateLimitStore(() => store);
    await Future.wait([
      limiter.attempt('login', 10, window),
      limiter.attempt('login', 10, window),
    ]);
    expect(await limiter.attempts('login', window), 1);
  });

  test('touch changes the lifetime, not the value', () async {
    final dir = Directory.systemTemp.createTempSync('touch_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final stores = <TouchableCacheStore>[MemoryStore(), FileStore(dir.path)];
    Clock.freeze();
    addTearDown(Clock.restore);
    for (final store in stores) {
      final start = Clock.now();
      await store.put('k', 5, ttl: const Duration(minutes: 1));
      expect(await store.touch('k', const Duration(hours: 1)), isTrue);
      // Past the original TTL: only the touched expiration keeps it.
      Clock.travel(const Duration(minutes: 2));
      expect(await store.get('k'), 5);
      Clock.travelTo(start);
      expect(await store.touch('missing', const Duration(hours: 1)), isFalse);
    }
  });
}
