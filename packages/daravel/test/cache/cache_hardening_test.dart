import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Cache store hardening (#167): `flexible()` refresh errors, `remember()`
/// waiters, locks across `flush()`, pruning and the `FileStore` lock.
void main() {
  tearDown(Clock.restore);

  group('flexible', () {
    test('a failing background refresh is reported, not thrown, and backs '
        'off instead of running on every stale hit', () async {
      Clock.freeze();
      final errors = <(String, Object)>[];
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final cache = CacheRepository(
          MemoryStore(),
          prefix: 'p_',
          onRefreshError: (key, error, _) => errors.add((key, error)),
        );
        var calls = 0;
        var fail = false;
        Future<String> compute() async {
          calls++;
          if (fail) {
            throw StateError('loader down');
          }
          return 'v$calls';
        }

        const window = (Duration(seconds: 10), Duration(minutes: 10));
        expect(await cache.flexible<String>('cfg', window, compute), 'v1');
        Clock.travel(const Duration(seconds: 11));
        fail = true;
        // Stale: the old value, and a refresh that fails.
        expect(await cache.flexible<String>('cfg', window, compute), 'v1');
        await _settle();
        expect(calls, 2);
        expect(errors.single.$1, 'cfg');
        expect(errors.single.$2, isA<StateError>());
        // Within the backoff no stale hit runs the loader again.
        for (var i = 0; i < 20; i++) {
          expect(await cache.flexible<String>('cfg', window, compute), 'v1');
        }
        await _settle();
        expect(calls, 2);
        // After it, one refresh, which now succeeds.
        Clock.travel(const Duration(seconds: 6));
        fail = false;
        expect(await cache.flexible<String>('cfg', window, compute), 'v1');
        await _settle();
        expect(calls, 3);
        expect(await cache.flexible<String>('cfg', window, compute), 'v3');
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty, reason: 'a script or isolate would die');
    });

    test(
      'without a handler the refresh error is dropped, not uncaught',
      () async {
        Clock.freeze();
        final uncaught = <Object>[];
        await runZonedGuarded(() async {
          final cache = CacheRepository(MemoryStore());
          const window = (Duration(seconds: 1), Duration(minutes: 1));
          await cache.flexible<int>('k', window, () => 1);
          Clock.travel(const Duration(seconds: 2));
          expect(
            await cache.flexible<int>('k', window, () => throw StateError('x')),
            1,
          );
          await _settle();
        }, (error, _) => uncaught.add(error));
        expect(uncaught, isEmpty);
      },
    );

    test('a refresh already running in this isolate takes no lock', () async {
      Clock.freeze();
      final coordinator = createStandardCoordinator();
      final channel = LocalCoordinatorChannel(coordinator);
      final cache = CacheRepository(ProcessStore(channel));
      const window = (Duration(seconds: 1), Duration(minutes: 1));
      await cache.flexible<int>('k', window, () => 1);
      Clock.travel(const Duration(seconds: 2));
      final gate = Completer<int>();
      await cache.flexible<int>('k', window, () => gate.future);
      final before = coordinator.stats()['messages']! as int;
      for (var i = 0; i < 10; i++) {
        await cache.flexible<int>('k', window, () => 3);
      }
      // One `get` per call, no lock call.
      expect((coordinator.stats()['messages']! as int) - before, 10);
      gate.complete(2);
      await _settle();
      expect(await cache.get<Map<String, Object?>>('k'), containsPair('v', 2));
    });
  });

  group('remember', () {
    test('concurrent misses in one isolate share one computation and one '
        'lock round trip', () async {
      final coordinator = createStandardCoordinator();
      final cache = CacheRepository(
        ProcessStore(LocalCoordinatorChannel(coordinator)),
      );
      var computed = 0;
      final results = await Future.wait([
        for (var i = 0; i < 50; i++)
          cache.remember<int>('answer', const Duration(minutes: 1), () async {
            computed++;
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return 42;
          }),
      ]);
      expect(results, everyElement(42));
      expect(computed, 1);
      // 50 first reads, then one acquire, read, put and release: the 50
      // waiters used to poll the lock (about 5 messages each).
      expect(coordinator.stats()['messages'], lessThan(60));
    });

    test('a waiter elsewhere reads the value as soon as it is stored, and '
        'gives up after lockTimeout', () async {
      final channel = LocalCoordinatorChannel(createStandardCoordinator());
      // Two stores over one coordinator: as two isolates are.
      final holder = CacheRepository(ProcessStore(channel));
      final waiter = CacheRepository(ProcessStore(channel));
      final gate = Completer<int>();
      final computing = holder.remember<int>('k', null, () => gate.future);
      await _settle();
      var waiterComputed = false;
      final waiting = waiter.remember<int>('k', null, () {
        waiterComputed = true;
        return 0;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete(7);
      expect(await computing, 7);
      expect(await waiting, 7);
      expect(waiterComputed, isFalse);

      final stuck = Completer<int>();
      unawaited(holder.remember<int>('slow', null, () => stuck.future));
      await _settle();
      await expectLater(
        waiter.remember<int>(
          'slow',
          null,
          () => 0,
          lockTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<LockTimeoutException>()),
      );
      stuck.complete(1);
    });

    test('a waiter takes the lock over when the holder failed', () async {
      final channel = LocalCoordinatorChannel(createStandardCoordinator());
      final holder = CacheRepository(ProcessStore(channel));
      final waiter = CacheRepository(ProcessStore(channel));
      final gate = Completer<int>();
      final failing = holder.remember<int>('k', null, () => gate.future);
      await _settle();
      final waiting = waiter.remember<int>('k', null, () => 9);
      gate.completeError(StateError('loader down'));
      await expectLater(failing, throwsStateError);
      expect(await waiting, 9);
    });
  });

  group('FileStore', () {
    late Directory temp;
    late String dir;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('daravel_file_hardening_');
      dir = p.join(temp.path, 'cache');
    });

    tearDown(() => temp.delete(recursive: true));

    test('concurrent acquires grant the lock once', () async {
      final store = FileStore(dir);
      final granted = await Future.wait([
        for (var i = 0; i < 50; i++)
          store.acquireLock('job', 'owner$i', const Duration(minutes: 1)),
      ]);
      expect(granted.where((g) => g), hasLength(1));
      final owner = await store.lockOwner('job');
      expect(owner, 'owner${granted.indexOf(true)}');
    });

    test('a lock file another process is still writing counts as held '
        'for a moment', () async {
      final store = FileStore(dir);
      expect(
        await store.acquireLock('job', 'a', const Duration(minutes: 1)),
        isTrue,
      );
      final lockFile = Directory(p.join(dir, 'locks'))
          .listSync()
          .whereType<File>()
          .single;
      // What process B saw between `create(exclusive)` and its write.
      lockFile.writeAsStringSync('');
      expect(
        await store.acquireLock('job', 'b', const Duration(minutes: 1)),
        isFalse,
      );
      expect(await store.lockOwner('job'), isNull);
      // Abandoned: older than the grace, it is free.
      lockFile.setLastModifiedSync(
        DateTime.now().subtract(FileStore.lockGrace * 2),
      );
      expect(
        await store.acquireLock('job', 'b', const Duration(minutes: 1)),
        isTrue,
      );
      expect(await store.lockOwner('job'), 'b');
    });

    test('release compares the owner: an expired holder does not delete '
        'the next one', () async {
      Clock.freeze();
      final store = FileStore(dir);
      expect(
        await store.acquireLock('job', 'a', const Duration(seconds: 1)),
        isTrue,
      );
      Clock.travel(const Duration(seconds: 2));
      expect(
        await store.acquireLock('job', 'b', const Duration(minutes: 1)),
        isTrue,
      );
      expect(await store.releaseLock('job', 'a'), isFalse);
      expect(await store.lockOwner('job'), 'b');
      // The owner extends its own lock.
      expect(
        await store.acquireLock('job', 'b', const Duration(minutes: 5)),
        isTrue,
      );
      expect(await store.releaseLock('job', 'b'), isTrue);
      expect(await store.lockOwner('job'), isNull);
    });

    test(
      'flush keeps the locks; prune deletes expired entries and locks',
      () async {
        Clock.freeze();
        final store = FileStore(dir, pruneInterval: null);
        await store.put('short', 1, ttl: const Duration(seconds: 1));
        await store.put('long', 1, ttl: const Duration(hours: 1));
        await store.increment('counter');
        expect(
          await store.acquireLock('held', 'a', const Duration(hours: 1)),
          isTrue,
        );
        expect(
          await store.acquireLock('stale', 'a', const Duration(seconds: 1)),
          isTrue,
        );
        Clock.travel(const Duration(seconds: 2));
        expect(await store.pruneExpired(), 2); // `short` and `stale`
        expect(await store.get('long'), 1);
        expect(await store.get('counter'), 1);
        expect(await store.lockOwner('held'), 'a');

        await store.flush();
        expect(await store.get('long'), isNull);
        expect(await store.lockOwner('held'), 'a');
        expect(
          await store.acquireLock('held', 'b', const Duration(hours: 1)),
          isFalse,
        );
        await store.flushLocks();
        expect(await store.lockOwner('held'), isNull);
      },
    );

    test('a write starts a background prune once per pruneInterval', () async {
      Clock.freeze();
      final store = FileStore(dir, pruneInterval: const Duration(hours: 1));
      await store.put('short', 1, ttl: const Duration(seconds: 1));
      expect(store.pruning, isNull);
      Clock.travel(const Duration(minutes: 30));
      await store.put('other', 1);
      expect(store.pruning, isNull, reason: 'the interval has not passed');
      expect(File(p.join(dir, 'locks')).existsSync(), isFalse);
      Clock.travel(const Duration(minutes: 31));
      await store.put('third', 1);
      expect(await store.pruning, 1);
      final files = Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .length;
      expect(files, 2);
    });
  });

  test('a ThrottleMiddleware built in code counts in the application '
      'limiter and finds its named limiters', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      App.make<RateLimiter>().define(
        'two',
        (request) => Limit.perMinute(2).by('everyone'),
      );
      const middleware = ThrottleMiddleware(limiterName: 'two');
      Future<Response> next(Request _) async => Response.text('ok');
      expect((await middleware.handle(Request.fake(), next)).status, 200);
      expect((await middleware.handle(Request.fake(), next)).status, 200);
      await expectLater(
        () => middleware.handle(Request.fake(), next),
        throwsA(isA<ThrottleRequestsException>()),
      );
    });
  });
}

/// Lets background work (a refresh, a release) run to completion.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
