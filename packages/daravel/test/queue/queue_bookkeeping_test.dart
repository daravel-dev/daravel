// Issue #161: the worker's own bookkeeping (listeners, signal store, lock
// stores, outages) must not leave jobs reserved, end the worker or leak
// unique and debounce locks.
import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final List<String> log = <String>[];

final class Plain extends Job {
  const Plain(this.name, {this.fail = false});
  final String name;
  final bool fail;
  @override
  String get jobName => 'plain';
  @override
  String? get uniqueId => name == 'unique' ? 'u' : null;
  @override
  Map<String, Object?> toJson() => {'name': name, 'fail': fail};
  @override
  Future<void> handle(JobContext ctx) async {
    log.add('plain:$name');
    if (fail) {
      throw StateError('boom');
    }
  }
}

final class Saved extends Job {
  const Saved(this.value);
  final int value;
  @override
  String get jobName => 'saved';
  @override
  Duration? get debounceFor => const Duration(seconds: 1);
  @override
  String get debounceId => 'doc';
  @override
  Map<String, Object?> toJson() => {'value': value};
  @override
  Future<void> handle(JobContext ctx) async => log.add('saved:$value');
}

final List<JobDefinition> definitions = [
  JobDefinition(
    'plain',
    (j) => Plain(j['name']! as String, fail: j['fail']! as bool),
  ),
  JobDefinition('saved', (j) => Saved(j['value']! as int)),
];

/// A memory store whose reads throw while [failing].
final class FlakyStore implements CacheStore {
  final MemoryStore inner = MemoryStore();
  bool failing = false;
  int reads = 0;

  void _check() {
    reads++;
    if (failing) {
      throw const FileSystemException('No space left on device');
    }
  }

  @override
  StateScope get scope => StateScope.process;
  @override
  Future<Object?> get(String key) async {
    _check();
    return inner.get(key);
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) => inner.many(keys);
  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      inner.put(key, value, ttl: ttl);
  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      inner.putMany(values, ttl: ttl);
  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      inner.add(key, value, ttl: ttl);
  @override
  Future<int> increment(String key, [int by = 1]) => inner.increment(key, by);
  @override
  Future<int> decrement(String key, [int by = 1]) => inner.decrement(key, by);
  @override
  Future<void> forever(String key, Object? value) => inner.forever(key, value);
  @override
  Future<bool> forget(String key) => inner.forget(key);
  @override
  Future<void> flush() => inner.flush();
  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) =>
      inner.acquireLock(name, owner, ttl);
  @override
  Future<bool> releaseLock(String name, String owner) =>
      inner.releaseLock(name, owner);
  @override
  Future<void> forceReleaseLock(String name) => inner.forceReleaseLock(name);
  @override
  Future<String?> lockOwner(String name) => inner.lockOwner(name);
}

/// A memory queue that is down for its first [outage] calls of `pop` and
/// `waitForWork`, and whose pushes fail while [refusePush].
final class Unreliable implements WakeableQueueDriver {
  Unreliable({this.outage = 0});
  final MemoryQueue inner = MemoryQueue();
  int outage;
  bool refusePush = false;
  int pops = 0;

  void _down() {
    if (outage > 0) {
      outage--;
      throw const SocketException('Connection refused');
    }
  }

  @override
  String get name => 'unreliable';
  @override
  StateScope get scope => StateScope.isolate;
  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) async {
    if (refusePush) {
      throw const SocketException('Connection refused');
    }
    return inner.push(payload, queue: queue, delay: delay);
  }

  @override
  Future<QueuedJob?> pop(String queue) async {
    pops++;
    _down();
    return inner.pop(queue);
  }

  @override
  Future<void> waitForWork(List<String> queues, Duration maxWait) async {
    _down();
    await inner.waitForWork(queues, maxWait);
  }

  @override
  Future<void> stopWaiting() => inner.stopWaiting();
  @override
  Future<void> release(QueuedJob job, Duration delay) =>
      inner.release(job, delay);
  @override
  Future<void> delete(QueuedJob job) => inner.delete(job);
  @override
  Future<int> size(String queue) => inner.size(queue);
  @override
  Future<Duration?> oldestWait(String queue) => inner.oldestWait(queue);
  @override
  Future<int> clear(String queue) => inner.clear(queue);
}

/// A database driver with PostgreSQL-style notifications that can be down
/// and whose `LISTEN` connection can drop.
final class FakeNotifying implements NotifyingDriver {
  bool down = false;
  final List<StreamController<String>> listens = [];

  @override
  String get name => 'fake';
  @override
  SqlDialect get dialect => SqlDialect.postgres;
  @override
  bool get isConnected => !down;
  @override
  Future<void> connect() async {
    if (down) {
      throw const SocketException('Connection refused');
    }
  }

  @override
  Future<void> close() async {}
  @override
  Stream<String> listen(String channel) {
    final controller = StreamController<String>();
    listens.add(controller);
    return controller.stream;
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => throw UnimplementedError();
  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => throw UnimplementedError();
  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => throw UnimplementedError();
  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      throw UnimplementedError();
}

void main() {
  Application? app;
  late FlakyStore flaky;
  late Unreliable unreliable;

  Future<void> boot([Map<String, String> env = const {}]) async {
    log.clear();
    flaky = FlakyStore();
    unreliable = Unreliable();
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_bookkeeping_')
                  .path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': 'memory',
              ...env,
            })
            .withCacheStore('flaky', (_) => flaky)
            .withQueueDriver('unreliable', (_) => unreliable)
            .withJobs(definitions)
            .create();
    await app!.boot();
  }

  tearDown(() async {
    await app?.shutdown();
    app = null;
  });

  group('lifecycle listeners that throw', () {
    test('JobProcessing: the job still runs and is removed', () async {
      await boot();
      await app!.run(() async {
        final spy = Log.spy();
        Event.listen<JobProcessing>((_) => throw StateError('listener'));
        await Queue.push(const Plain('a'));
        await QueueWorker(Queue.manager)
            .run(const WorkerOptions(stopWhenEmpty: true));
        expect(log, ['plain:a']);
        expect(await Queue.size(), 0);
        spy.assertLogged(LogLevel.error, 'JobProcessing listener threw');
      });
    });

    test('JobExceptionOccurred and JobFailed: the failure is recorded and '
        'the unique lock released', () async {
      await boot();
      await app!.run(() async {
        Event.listen<JobExceptionOccurred>((_) => throw StateError('one'));
        Event.listen<JobFailed>((_) => throw StateError('two'));
        await Queue.push(const Plain('unique', fail: true));
        await QueueWorker(Queue.manager)
            .run(const WorkerOptions(stopWhenEmpty: true));
        expect(await Queue.size(), 0);
        expect(await Queue.manager.processor.failedJobs.all(), hasLength(1));
        expect(await Queue.push(const Plain('unique')), isNotNull);
      });
    });
  });

  test('a signal store that fails does not end the worker', () async {
    await boot({'QUEUE_SIGNAL_STORE': 'flaky'});
    await app!.run(() async {
      await Queue.push(const Plain('a'));
      await Queue.push(const Plain('b'));
      final worker = QueueWorker(Queue.manager, logger: Log.logger);
      final spy = Log.spy();
      // The read at start succeeds; every later one throws.
      Event.listen<JobProcessed>((_) => flaky.failing = true);
      expect(
        await worker.run(const WorkerOptions(maxJobs: 2, sleep: Duration.zero)),
        0,
      );
      expect(log, ['plain:a', 'plain:b']);
      expect(flaky.reads, greaterThan(2));
      spy.assertLogged(LogLevel.error, 'queue:restart signal');
    });
  });

  test('a worker started during an outage waits and recovers', () async {
    await boot();
    await app!.run(() async {
      unreliable.outage = 4;
      await Queue.push(const Plain('a'), connection: 'unreliable');
      final spy = Log.spy();
      final code = await QueueWorker(Queue.manager, logger: Log.logger).run(
        const WorkerOptions(
          connection: 'unreliable',
          sleep: Duration(milliseconds: 1),
          maxJobs: 1,
        ),
      );
      expect(code, 0);
      expect(log, ['plain:a']);
      expect(unreliable.pops, 5);
      // One stack trace for the outage, not one per poll.
      expect(spy.matching(LogLevel.error), hasLength(1));
      spy.assertLogged(LogLevel.info, 'recovered after 4 errors');
    });
  });

  test('the wait between failed polls doubles up to a minute', () {
    const sleep = Duration(seconds: 3);
    expect(QueueWorker.errorBackoff(sleep, 1), sleep);
    expect(QueueWorker.errorBackoff(sleep, 2), const Duration(seconds: 6));
    expect(QueueWorker.errorBackoff(sleep, 4), const Duration(seconds: 24));
    expect(QueueWorker.errorBackoff(sleep, 30), const Duration(minutes: 1));
    expect(
      QueueWorker.errorBackoff(const Duration(minutes: 2), 5),
      const Duration(minutes: 2),
    );
  });

  test('--memory stops the worker with exit code 12', () async {
    await boot();
    await app!.run(() async {
      await Queue.push(const Plain('a'));
      await Queue.push(const Plain('b'));
      final code = await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true, memory: 1));
      expect(code, QueueWorker.exitMemoryLimit);
      expect(log, ['plain:a']);
    });
  });

  group('a push that fails', () {
    test('releases the unique lock', () async {
      await boot();
      await app!.run(() async {
        unreliable.refusePush = true;
        await expectLater(
          Queue.push(const Plain('unique'), connection: 'unreliable'),
          throwsA(isA<SocketException>()),
        );
        expect(await Queue.push(const Plain('unique')), isNotNull);
      });
    });

    test('keeps the debounced dispatch already queued', () async {
      await boot();
      await app!.run(() async {
        await Queue.push(const Saved(1), connection: 'unreliable');
        unreliable.refusePush = true;
        await expectLater(
          Queue.push(const Saved(2), connection: 'unreliable'),
          throwsA(isA<SocketException>()),
        );
        unreliable.refusePush = false;
        final clock = DateTime.now().add(const Duration(seconds: 2));
        Clock.travelTo(clock);
        addTearDown(Clock.restore);
        await QueueWorker(Queue.manager).run(
          const WorkerOptions(connection: 'unreliable', stopWhenEmpty: true),
        );
        expect(log, ['saved:1']);
      });
    });
  });

  test('listeners of one priority run in registration order', () async {
    final events = EventDispatcher();
    final order = <int>[];
    for (var i = 0; i < 40; i++) {
      events.listen<String>((_) => order.add(i));
    }
    events.listen<String>((_) => order.add(-1), priority: 10);
    events.listen<String>((_) => order.add(100), priority: -1);
    await events.dispatch('go');
    expect(order, [-1, for (var i = 0; i < 40; i++) i, 100]);
  });

  test('a unique-lock store of one isolate cannot serve several', () async {
    await boot({
      'QUEUE_CONNECTION': 'database',
      'QUEUE_UNIQUE_LOCK_STORE': 'memory',
    });
    for (final options in const [
      ServeOptions(isolates: 2, port: 0),
      ServeOptions(embedQueue: true, port: 0),
    ]) {
      await expectLater(
        app!.serve(options: options),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('QUEUE_UNIQUE_LOCK_STORE=memory'),
          ),
        ),
      );
    }
  });

  group('DatabaseQueue LISTEN', () {
    late FakeNotifying driver;
    late DatabaseManager db;

    setUp(() {
      driver = FakeNotifying();
      db = DatabaseManager(
        const DatabaseConfig(
          defaultConnection: 'fake',
          connections: {
            'fake': ConnectionConfig(driver: 'fake', database: 'fake'),
          },
        ),
        drivers: {'fake': (_, _) => driver},
      );
    });

    test('a database down at start is listened to once it is back', () async {
      final queue = DatabaseQueue(db, listenRetry: Duration.zero);
      addTearDown(queue.stopWaiting);
      driver.down = true;
      await queue.waitForWork(['default'], Duration.zero);
      expect(driver.listens, isEmpty);

      driver.down = false;
      final waiting = queue.waitForWork(['default'], const Duration(hours: 1));
      await Future<void>.delayed(Duration.zero);
      expect(driver.listens, hasLength(1));
      driver.listens.single.add('default');
      await waiting;
    });

    test('a dropped LISTEN is opened again after listenRetry', () async {
      final queue = DatabaseQueue(db, listenRetry: Duration.zero);
      addTearDown(queue.stopWaiting);
      await queue.waitForWork(['default'], Duration.zero);
      expect(driver.listens, hasLength(1));
      await driver.listens.single.close();
      await Future<void>.delayed(Duration.zero);

      final waiting = queue.waitForWork(['default'], const Duration(hours: 1));
      await Future<void>.delayed(Duration.zero);
      expect(driver.listens, hasLength(2));
      driver.listens.last.add('default');
      await waiting;
    });

    test('within listenRetry the wait sleeps instead', () async {
      final queue = DatabaseQueue(db);
      addTearDown(queue.stopWaiting);
      await queue.waitForWork(['default'], Duration.zero);
      await driver.listens.single.close();
      await Future<void>.delayed(Duration.zero);
      await queue.waitForWork(['default'], Duration.zero);
      expect(driver.listens, hasLength(1));
    });
  });
}
