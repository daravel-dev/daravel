import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Counts the coordinator round trips of a channel.
final class _CountingChannel implements CoordinatorChannel {
  _CountingChannel(this._inner);

  final CoordinatorChannel _inner;
  final List<String> ops = [];

  @override
  StateScope get scope => _inner.scope;

  @override
  bool get isRemote => _inner.isRemote;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    ops.add(op);
    return _inner.call(service, op, args, timeout: timeout);
  }
}

void main() {
  group('ProcessStore near cache (L1)', () {
    late Coordinator coordinator;
    late _CountingChannel channel;

    setUp(() {
      coordinator = createStandardCoordinator();
      channel = _CountingChannel(LocalCoordinatorChannel(coordinator));
    });
    tearDown(() => coordinator.close());

    test('off by default: every read asks the coordinator', () async {
      final store = ProcessStore(channel);
      await store.put('flag', true);
      await store.get('flag');
      await store.get('flag');
      expect(channel.ops, ['put', 'get', 'get']);
    });

    test('repeated reads are local; own writes are seen at once', () async {
      final store = ProcessStore(channel, l1Ttl: const Duration(seconds: 5));
      await store.put('flag', 'on');
      expect(await store.get('flag'), 'on');
      expect(await store.get('flag'), 'on');
      expect(channel.ops, ['put'], reason: 'put fills the near cache');

      await store.put('flag', 'off');
      expect(await store.get('flag'), 'off');
      await store.forget('flag');
      expect(await store.get('flag'), isNull);
      expect(channel.ops, ['put', 'put', 'forget', 'get']);
    });

    test('another isolate\'s writes show up after l1Ttl', () async {
      final mine = ProcessStore(
        channel,
        l1Ttl: const Duration(milliseconds: 60),
      );
      final theirs = ProcessStore(LocalCoordinatorChannel(coordinator));
      await theirs.put('plan', 'free');
      expect(await mine.get('plan'), 'free');
      await theirs.put('plan', 'pro');
      expect(await mine.get('plan'), 'free', reason: 'within the window');
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(await mine.get('plan'), 'pro');
    });

    test('misses and counters are never cached; values are copies', () async {
      final store = ProcessStore(
        channel,
        l1Ttl: const Duration(seconds: 5),
        l1MaxEntries: 2,
      );
      await store.get('missing');
      await store.get('missing');
      expect(channel.ops, ['get', 'get']);

      await store.put('hits', 1);
      await store.increment('hits');
      expect(await store.get('hits'), 2, reason: 'increment drops the entry');

      await store.put('settings', {'theme': 'dark'});
      final read = (await store.get('settings'))! as Map<Object?, Object?>;
      read['theme'] = 'changed';
      expect(await store.get('settings'), {'theme': 'dark'});

      // Bounded: the oldest entry goes first.
      channel.ops.clear();
      await store.put('a', 1);
      await store.put('b', 2);
      await store.put('c', 3);
      await store.get('a');
      expect(channel.ops.last, 'get', reason: 'a was evicted');
    });
  });

  group('CacheRateLimitStore', () {
    late CacheRateLimitStore limiter;
    const window = Duration(minutes: 1);

    setUp(() {
      Clock.freeze();
      final memory = MemoryStore();
      limiter = CacheRateLimitStore(() => memory);
    });
    tearDown(Clock.restore);

    test(
      'counts up to the limit and does not count blocked attempts',
      () async {
        final first = await limiter.attempt('login:ana', 2, window);
        expect((first.allowed, first.remaining), (true, 1));
        expect((await limiter.attempt('login:ana', 2, window)).allowed, isTrue);
        final blocked = await limiter.attempt('login:ana', 2, window);
        expect(blocked.allowed, isFalse);
        expect(blocked.retryAfter, window);
        expect(await limiter.attempts('login:ana', window), 2);
        expect(await limiter.availableIn('login:ana', 2, window), window);
        expect((await limiter.attempt('login:bo', 2, window)).allowed, isTrue);
      },
    );

    test('the window ends and clear() resets a key', () async {
      await limiter.attempt('k', 1, window);
      expect((await limiter.attempt('k', 1, window)).allowed, isFalse);
      Clock.travel(const Duration(minutes: 1, seconds: 1));
      expect((await limiter.attempt('k', 1, window)).allowed, isTrue);
      await limiter.clear('k');
      expect(await limiter.attempts('k', window), 0);
      expect(limiter.flush, throwsUnsupportedError);
    });
  });

  test('CACHE_LIMITER selects a cache-backed rate limiter', () async {
    final base = Directory.systemTemp.createTempSync('daravel_limiter');
    addTearDown(() => base.deleteSync(recursive: true));
    final app = Application.configure(basePath: base.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'CACHE_LIMITER': 'memory',
        })
        .withRateLimits(
          (limiter) =>
              limiter.define('tight', (_) => Limit.perMinute(1).by('ip')),
        )
        .withRouting(
          api: (r) =>
              r.get('/ping', (_) => 'pong').middleware(['throttle:tight']),
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    expect(app.container.make<RateLimiter>().store, isA<CacheRateLimitStore>());
    final first = await app.handle(Request.fake(path: '/api/ping'));
    final second = await app.handle(Request.fake(path: '/api/ping'));
    expect((first.status, second.status), (200, 429));
  });
}
