import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/concurrency/compute_pool.dart';
import 'package:test/test.dart';

/// Holds its worker until [path] exists: the test decides when it ends, so
/// nothing depends on how long anything takes.
int holdUntil(String path) {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!File(path).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Never released.');
    }
    sleep(const Duration(milliseconds: 5));
  }
  return 0;
}

FutureOr<int> Function() holder(String path) =>
    () => holdUntil(path);

void main() {
  late Directory dir;
  late String gate;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daravel_pool_');
    gate = '${dir.path}/release';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void release() => File(gate).writeAsStringSync('go');

  group('ComputePool', () {
    test('timeout runs from the call: it covers the wait for a busy '
        'worker', () async {
      final pool = ComputePool(() => 1);
      addTearDown(pool.shutdown);
      final busy = pool.run(holder(gate));
      await expectLater(
        pool.run(() => 1, timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      // The waiter that timed out left the queue.
      expect(pool.waiting, 0);
      release();
      expect(await busy, 0);
      expect(await pool.run(() => 2), 2);
    });

    test('past maxQueue a task fails at once', () async {
      final pool = ComputePool(() => 1, maxQueue: () => 2);
      addTearDown(pool.shutdown);
      final busy = pool.run(holder(gate));
      final queued = [pool.run(() => 1), pool.run(() => 2)];
      expect(pool.waiting, 2);
      await expectLater(
        pool.run(() => 3),
        throwsA(isA<ComputePoolSaturatedError>()),
      );
      release();
      expect(await busy, 0);
      expect(await Future.wait(queued), [1, 2]);
    });

    test('queueTimeout bounds the wait alone, as saturation', () async {
      final pool = ComputePool(() => 1);
      addTearDown(pool.shutdown);
      final busy = pool.run(holder(gate));
      await expectLater(
        pool.run(() => 1, queueTimeout: const Duration(milliseconds: 50)),
        throwsA(isA<ComputePoolSaturatedError>()),
      );
      release();
      expect(await busy, 0);
    });

    test('a failed spawn does not strand the tasks queued behind it', () async {
      var spawns = 0;
      final pool = ComputePool(
        () => 1,
        beforeSpawn: () {
          if (spawns++ == 0) {
            throw StateError('The worker exited at start.');
          }
        },
      );
      addTearDown(pool.shutdown);
      final first = pool.run(() => 1);
      // Queued while the first spawn is in flight.
      final second = pool.run(() => 2);
      expect(pool.waiting, 1);
      await expectLater(first, throwsStateError);
      expect(await second.timeout(const Duration(seconds: 20)), 2);
    });
  });

  test('Concurrency.maxQueue refuses tasks past it', () async {
    Concurrency.maxWorkers = 1;
    Concurrency.maxQueue = 0;
    addTearDown(() async {
      Concurrency.maxQueue = null;
      Concurrency.maxWorkers = 2;
      await Concurrency.shutdown();
    });
    final busy = Concurrency.run<int>([holder(gate)]);
    await expectLater(
      Concurrency.run<int>([() => 1]),
      throwsA(isA<StateError>()),
    );
    release();
    expect(await busy, [0]);
    expect(() => Concurrency.maxQueue = -1, throwsRangeError);
  });

  group('HashManager', () {
    HashManager manager({int concurrency = 2, int? maxQueue = 1024}) {
      final hash = HashManager(
        HashConfig(
          bcryptRounds: 4,
          concurrency: concurrency,
          maxQueue: maxQueue,
        ),
      );
      addTearDown(hash.close);
      return hash;
    }

    test('never runs more hashes at once than HASH_CONCURRENCY', () async {
      final hash = manager();
      final hashed = await hash.make('secret');
      final checks = [for (var i = 0; i < 8; i++) hash.check('secret', hashed)];
      // Two isolates at most; the other six wait for them.
      expect(hash.waiting, 6);
      expect(hash.isolates, lessThanOrEqualTo(2));
      expect(await Future.wait(checks), everyElement(isTrue));
      expect(hash.isolates, 2);
      // Still Laravel's format (ADR-024).
      expect(hashed, startsWith(r'$2y$04$'));
    });

    test('a full queue is a 503, and checkAgainstDummy recovers from a '
        'failed dummy hash', () async {
      final hash = manager(concurrency: 1, maxQueue: 1);
      final running = hash.make('a');
      final queued = hash.make('b');
      final refused = hash.make('c');
      await expectLater(
        refused,
        throwsA(
          isA<HashingSaturatedException>()
              .having((e) => e.status, 'status', 503)
              .having((e) => e.headers['Retry-After'], 'Retry-After', '1'),
        ),
      );
      // The dummy hash is refused too, and not cached as a failure.
      await expectLater(
        hash.checkAgainstDummy('x'),
        throwsA(isA<HashingSaturatedException>()),
      );
      await Future.wait([running, queued]);
      await hash.checkAgainstDummy('x');
    });

    test('HASH_CONCURRENCY, HASH_QUEUE and HASH_QUEUE_TIMEOUT', () {
      final defaults = HashConfig.fromEnv(Env.fromMap(const {}));
      expect(defaults.concurrency, isNull);
      expect(defaults.effectiveConcurrency, Platform.numberOfProcessors);
      expect(defaults.maxQueue, HashConfig.defaultMaxQueue);
      expect(defaults.queueTimeout, const Duration(seconds: 30));
      final set = HashConfig.fromEnv(
        Env.fromMap(const {
          'HASH_CONCURRENCY': '3',
          'HASH_QUEUE': '0',
          'HASH_QUEUE_TIMEOUT': '5s',
        }),
      );
      expect(set.effectiveConcurrency, 3);
      expect(set.maxQueue, isNull);
      expect(set.queueTimeout, const Duration(seconds: 5));
      expect(
        () => HashConfig.fromEnv(Env.fromMap(const {'HASH_CONCURRENCY': '-1'})),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
