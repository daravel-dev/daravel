import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryStore', () {
    final start = DateTime.utc(2026, 10, 24, 12);
    var now = start;
    late MemoryStore store;

    setUp(() {
      now = start;
      store = MemoryStore(maxEntries: 3, clock: () => now);
    });

    test('ttl, forever, add, increment, forget, flush', () async {
      await store.put('a', 1, ttl: const Duration(seconds: 10));
      await store.forever('b', 'x');
      expect(await store.get('a'), 1);
      expect(await store.add('a', 9), isFalse);
      now = now.add(const Duration(seconds: 11));
      expect(await store.get('a'), isNull);
      expect(await store.add('a', 9), isTrue);
      expect(await store.get('b'), 'x');
      expect(await store.increment('n'), 1);
      expect(await store.increment('n', 4), 5);
      expect(await store.decrement('n', 2), 3);
      expect(await store.forget('n'), isTrue);
      expect(await store.forget('n'), isFalse);
      expect(await store.many(['a', 'b', 'zzz']), {
        'a': 9,
        'b': 'x',
        'zzz': null,
      });
      await store.flush();
      expect(store.size, 0);
    });

    test('evicts least recently used beyond maxEntries', () async {
      await store.putMany({'k1': 1, 'k2': 2, 'k3': 3});
      await store.get('k1'); // touch → k2 is now the oldest
      await store.put('k4', 4);
      expect(store.size, 3);
      expect(await store.get('k2'), isNull);
      expect(await store.get('k1'), 1);
    });

    test('locks respect owner and ttl', () async {
      expect(
        await store.acquireLock('L', 'a', const Duration(seconds: 5)),
        isTrue,
      );
      expect(
        await store.acquireLock('L', 'b', const Duration(seconds: 5)),
        isFalse,
      );
      expect(
        await store.acquireLock('L', 'a', const Duration(seconds: 5)),
        isTrue,
      ); // re-entrant for owner
      expect(await store.lockOwner('L'), 'a');
      now = now.add(const Duration(seconds: 6));
      expect(await store.lockOwner('L'), isNull);
      expect(
        await store.acquireLock('L', 'b', const Duration(seconds: 5)),
        isTrue,
      );
      await store.forceReleaseLock('L');
      expect(await store.lockOwner('L'), isNull);
    });
  });

  group('FileStore', () {
    late Directory dir;
    late FileStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('daravel_cache_');
      store = FileStore(dir.path);
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('persists JSON values atomically with expiry', () async {
      await store.put('user:1', {
        'name': 'Ana',
      }, ttl: const Duration(minutes: 1));
      await store.put('gone', 1, ttl: const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await store.get('user:1'), {'name': 'Ana'});
      expect(await store.get('gone'), isNull);
      expect(await store.add('user:1', 0), isFalse);
      expect(await store.increment('hits', 2), 2);
      expect(await store.increment('hits'), 3);
      expect(await store.forget('hits'), isTrue);
      expect(await store.get('hits'), isNull);
      // Same key → same file, no leftovers from the temp file.
      await store.put('user:1', 'again');
      final files = dir.listSync(recursive: true).whereType<File>().toList();
      expect(files.where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(await store.get('user:1'), 'again');
      await store.flush();
      expect(await store.get('user:1'), isNull);
    });

    test('locks use exclusive file creation', () async {
      expect(
        await store.acquireLock('job', 'w1', const Duration(seconds: 5)),
        isTrue,
      );
      expect(
        await store.acquireLock('job', 'w2', const Duration(seconds: 5)),
        isFalse,
      );
      expect(await store.lockOwner('job'), 'w1');
      expect(await store.releaseLock('job', 'w2'), isFalse);
      expect(await store.releaseLock('job', 'w1'), isTrue);
      expect(
        await store.acquireLock('job', 'w2', const Duration(milliseconds: 1)),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // Expired locks can be taken over.
      expect(
        await store.acquireLock('job', 'w3', const Duration(seconds: 5)),
        isTrue,
      );
      expect(await store.lockOwner('job'), 'w3');
    });
  });

  group('DatabaseStore + CacheRepository + facade', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'CACHE_STORE': 'memory',
            'CACHE_PREFIX': 'test_',
          })
          .withMigrations(const [CreateCacheTable()])
          .create();
      await app.boot();
      await app.run(() => App.make<Migrator>().run());
    });

    tearDown(() => app.shutdown());

    test('database store uses the Laravel cache tables', () async {
      await app.run(() async {
        final cache = Cache.store('database');
        expect(cache.scope, StateScope.cluster);
        await cache.put('k', [1, 2], ttl: const Duration(minutes: 1));
        expect(await cache.get<List<Object?>>('k'), [1, 2]);
        final row = await DB.table('cache').where('key', 'test_k').first();
        expect(
          row!['expiration'],
          greaterThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        );
        expect(await cache.add('k', 'x'), isFalse);
        expect(await cache.increment('n', 2), 2);
        expect(await cache.increment('n'), 3);
        await cache.forever('f', 'v');
        expect(
          (await DB
              .table('cache')
              .where('key', 'test_f')
              .first())!['expiration'],
          DatabaseStore.foreverExpiration,
        );
        expect(await cache.pull<String>('f'), 'v');
        expect(await cache.has('f'), isFalse);

        final lock = cache.lock(
          'report',
          ttl: const Duration(seconds: 5),
          owner: 'me',
        );
        expect(await lock.acquire(), isTrue);
        expect(await cache.lock('report', owner: 'other').acquire(), isFalse);
        expect(await lock.currentOwner(), 'me');
        expect(await lock.release(), isTrue);
        expect(await cache.lock('report', owner: 'other').acquire(), isTrue);
        await cache.flush();
        expect(await DB.table('cache_locks').count(), 0);
      });
    });

    test('remember computes once under concurrency (stampede guard)', () async {
      await app.run(() async {
        var computed = 0;
        Future<int> compute() async {
          computed++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return 42;
        }

        final results = await Future.wait([
          for (var i = 0; i < 5; i++)
            Cache.remember<int>('answer', const Duration(minutes: 1), compute),
        ]);
        expect(results, everyElement(42));
        expect(computed, 1);
        expect(await Cache.get<int>('answer'), 42);
        expect(await Cache.rememberForever<int>('answer', () => 0), 42);
      });
    });

    test(
      'flexible serves stale values and refreshes in the background',
      () async {
        await app.run(() async {
          var calls = 0;
          Future<String> compute() async => 'v${++calls}';
          const window = (Duration(milliseconds: 20), Duration(seconds: 10));
          expect(await Cache.flexible<String>('cfg', window, compute), 'v1');
          expect(await Cache.flexible<String>('cfg', window, compute), 'v1');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          // Stale: old value returned, refresh scheduled.
          expect(await Cache.flexible<String>('cfg', window, compute), 'v1');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(await Cache.flexible<String>('cfg', window, compute), 'v2');
          expect(calls, 2);
        });
      },
    );

    test('lock.block waits and throws LockTimeoutException', () async {
      await app.run(() async {
        final held = Cache.lock('slot', ttl: const Duration(seconds: 5));
        expect(await held.acquire(), isTrue);
        await expectLater(
          () => Cache.lock(
            'slot',
          ).block(const Duration(milliseconds: 150), () => 'never'),
          throwsA(isA<LockTimeoutException>()),
        );
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 50), held.release),
        );
        expect(
          await Cache.lock(
            'slot',
          ).block(const Duration(seconds: 2), () => 'got it'),
          'got it',
        );
        // Callback form releases afterwards.
        expect(await Cache.lock('slot').get(() async {}), isTrue);
        expect(await Cache.lock('slot').acquire(), isTrue);
      });
    });

    test('manager resolves stores and prefixes keys', () async {
      await app.run(() async {
        expect(
          Cache.manager.storeNames,
          containsAll(['memory', 'process', 'file', 'database']),
        );
        expect(Cache.store().scope, StateScope.isolate);
        expect(Cache.store('process').scope, StateScope.process);
        await Cache.store('process').put('shared', 1);
        expect(await Cache.store('process').get<int>('shared'), 1);
        expect(await Cache.get<int>('shared'), isNull);
        expect(() => Cache.store('redis'), throwsA(isA<ConfigException>()));
        await Cache.put('x', 1);
        expect(await (Cache.store().store).get('test_x'), 1);
      });
    });
  });
}
