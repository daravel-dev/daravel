@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

final class Ping extends Job {
  const Ping(this.text);

  factory Ping.fromJson(Map<String, Object?> json) =>
      Ping(json['text']! as String);

  final String text;

  static final List<String> ran = [];

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => {'text': text};

  @override
  Future<void> handle(JobContext context) async => ran.add(text);
}

/// Runs against a real Redis or Valkey when `DARAVEL_TEST_REDIS` is set
/// (`redis://127.0.0.1:6379/15`); every test writes under a prefix of its
/// own and deletes it afterwards.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test('Redis (skipped: DARAVEL_TEST_REDIS not set)', () {}, skip: true);
    return;
  }
  final server = RedisConnectionConfig.fromUrl(url);
  late String prefix;
  late RedisClient client;

  setUp(() {
    prefix = 'test_${Random().nextInt(1 << 32)}_';
    client = RedisClient(server);
  });

  tearDown(() async {
    var cursor = '0';
    do {
      final reply =
          (await client.command(['SCAN', cursor, 'MATCH', '$prefix*']))!
              as List;
      cursor = reply[0]! as String;
      final keys = (reply[1]! as List).cast<String>();
      if (keys.isNotEmpty) {
        await client.command(['DEL', ...keys]);
      }
    } while (cursor != '0');
    await client.close();
  });

  group('client', () {
    test('concurrent commands pipeline on one connection, in order', () async {
      final replies = await Future.wait([
        for (var i = 0; i < 1000; i++)
          client.command(['INCR', '${prefix}counter']),
      ]);
      expect(replies, [for (var i = 1; i <= 1000; i++) i]);
    });

    test(
      'more commands in flight than REDIS_MAX_IN_FLIGHT are refused',
      () async {
        final small = RedisClient(
          RedisConnectionConfig(
            host: server.host,
            port: server.port,
            database: server.database,
            maxInFlight: 10,
          ),
        );
        addTearDown(small.close);
        await small.command(['PING']);
        final results = await Future.wait([
          for (var i = 0; i < 20; i++)
            small
                .command(['PING'])
                .then<Object?>((r) => r, onError: (Object e) => e),
        ]);
        expect(results.whereType<RedisOverloadedException>(), hasLength(10));
        expect(results.where((r) => r == 'PONG'), hasLength(10));
      },
    );

    test('an error reply throws and the connection carries on', () async {
      await client.set('${prefix}text', 'abc');
      await expectLater(
        client.command(['INCR', '${prefix}text']),
        throwsA(isA<RedisCommandException>()),
      );
      expect(await client.get('${prefix}text'), 'abc');
    });

    test('a script loads itself when the server does not know it', () async {
      final script = RedisScript(
        "return redis.call('INCRBY', KEYS[1], ARGV[1]) -- $prefix",
      );
      expect(await client.eval(script, keys: ['${prefix}n'], args: [5]), 5);
      expect(await client.eval(script, keys: ['${prefix}n'], args: [5]), 10);
    });

    test('a timeout closes the connection; the next command reconnects', () {
      return () async {
        final slow = RedisClient(
          RedisConnectionConfig(
            host: server.host,
            port: server.port,
            database: server.database,
            commandTimeout: const Duration(milliseconds: 100),
          ),
        );
        addTearDown(slow.close);
        await expectLater(
          slow.command(['BLPOP', '${prefix}never', '1']),
          throwsA(isA<RedisConnectionException>()),
        );
        expect(await slow.command(['PING']), 'PONG');
      }();
    });

    test('sharded pub/sub (Redis 7)', () async {
      final subscription = client.subscribe(['${prefix}shard'], sharded: true);
      addTearDown(subscription.cancel);
      final received = subscription.messages.first;
      await subscription.ready;
      expect(await client.publish('${prefix}shard', 'hi', sharded: true), 1);
      expect((await received).payload, 'hi');
    });

    test('pub/sub delivers to subscribers', () async {
      final subscription = client.subscribe(['${prefix}news']);
      await subscription.ready;
      final received = subscription.messages.first;
      expect(await client.publish('${prefix}news', 'hello'), 1);
      expect((await received).payload, 'hello');
      await subscription.cancel();
    });
  });

  group('cache store', () {
    late RedisStore store;
    setUp(() => store = RedisStore(client, prefix: prefix, flushPrefix: 'c:'));

    test('get, put, many, add, forget', () async {
      await store.put('c:a', {'x': 1});
      await store.put('c:n', 5);
      expect(await store.get('c:a'), {'x': 1});
      expect(await store.get('c:n'), 5);
      expect(await client.get('${prefix}c:n'), '5', reason: 'numbers raw');
      expect(await store.many(['c:a', 'c:missing']), {
        'c:a': {'x': 1},
        'c:missing': null,
      });
      expect(await store.add('c:a', 'no'), isFalse);
      expect(
        await store.add('c:b', 'yes', ttl: const Duration(seconds: 5)),
        isTrue,
      );
      expect(await store.forget('c:b'), isTrue);
      expect(await store.forget('c:b'), isFalse);
    });

    test('increment, ttl and touch', () async {
      expect(await store.increment('c:hits'), 1);
      expect(await store.increment('c:hits', 4), 5);
      expect(await store.decrement('c:hits', 2), 3);
      await store.put('c:short', 'v', ttl: const Duration(milliseconds: 200));
      expect(await store.touch('c:short', const Duration(seconds: 30)), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await store.get('c:short'), 'v');
      expect(await store.touch('c:none', const Duration(seconds: 1)), isFalse);
    });

    test('flush deletes this cache only', () async {
      await store.put('c:one', 1);
      await store.put('c:two', 2);
      await client.set('${prefix}queue:keep', 'job');
      await store.flush();
      expect(await store.get('c:one'), isNull);
      expect(await store.get('c:two'), isNull);
      expect(await client.get('${prefix}queue:keep'), 'job');
    });

    test('locks belong to their owner', () async {
      const ttl = Duration(seconds: 5);
      expect(await store.acquireLock('report', 'a', ttl), isTrue);
      expect(await store.acquireLock('report', 'b', ttl), isFalse);
      expect(await store.lockOwner('report'), 'a');
      // Laravel's RedisLock key: connection prefix + (cache prefix +) name.
      expect(await client.get('${prefix}report'), 'a');
      expect(await store.releaseLock('report', 'b'), isFalse);
      expect(await store.releaseLock('report', 'a'), isTrue);
      expect(await store.acquireLock('report', 'b', ttl), isTrue);
      await store.forceReleaseLock('report');
      expect(await store.lockOwner('report'), isNull);
    });

    test(
      'a rate limit window in one script: blocked hits do not count',
      () async {
        const window = Duration(seconds: 30);
        final results = await Future.wait([
          for (var i = 0; i < 25; i++) store.hitWindow('rl', 10, window),
        ]);
        expect(results.where((r) => r.allowed), hasLength(10));
        expect(results.map((r) => r.hits).reduce(max), 10);
        final current = (await store.currentWindow('rl'))!;
        expect(current.hits, 10);
        expect(
          current.resetAt.difference(DateTime.now().toUtc()),
          greaterThan(const Duration(seconds: 25)),
        );
        expect(await store.currentWindow('other'), isNull);
      },
    );
  });

  group('rate limit algorithms', () {
    late RedisStore store;
    setUp(() => store = RedisStore(client, prefix: prefix));

    test('GCRA spreads the limit; a refused hit is not counted', () async {
      const window = Duration(milliseconds: 600);
      final hits = [
        for (var i = 0; i < 4; i++) await store.hitGcra('g', 3, window),
      ];
      expect([for (final h in hits) h.allowed], [true, true, true, false]);
      expect([for (final h in hits) h.remaining], [2, 1, 0, 0]);
      // One hit every 200ms once the burst is spent.
      expect(hits[3].retryAfter.inMilliseconds, inInclusiveRange(1, 200));
      await Future<void>.delayed(
        hits[3].retryAfter + const Duration(milliseconds: 20),
      );
      expect((await store.hitGcra('g', 3, window)).allowed, isTrue);
      expect((await store.hitGcra('g', 3, window)).allowed, isFalse);
    });

    test('a sliding window has no burst at the reset', () async {
      const window = Duration(milliseconds: 800);
      final hits = [
        for (var i = 0; i < 5; i++)
          await store.hitSlidingWindow('s', 4, window),
      ];
      expect(
        [for (final h in hits) h.allowed],
        [true, true, true, true, false],
      );
      final wait = hits[4].retryAfter;
      expect(wait, greaterThan(Duration.zero));
      await Future<void>.delayed(wait + const Duration(milliseconds: 30));
      expect((await store.hitSlidingWindow('s', 4, window)).allowed, isTrue);
    });
  });

  for (final engine in RedisQueueEngine.values) {
    group('queue (${engine.name})', () {
      late RedisQueue queue;
      setUp(
        () => queue = RedisQueue(
          client,
          prefix: prefix,
          retryAfter: const Duration(milliseconds: 300),
          engine: engine,
        ),
      );
      tearDown(() => queue.stopWaiting());

      JobPayload payload(String text) => JobPayload.forJob(Ping(text));

      test('push, pop, delete; the payload stays byte for byte', () async {
        final job = payload('one');
        await queue.push(job, queue: 'default');
        expect(await queue.size('default'), 1);
        final popped = (await queue.pop('default'))!;
        expect(popped.raw, job.encode());
        expect(popped.attempts, 1);
        expect(await queue.pop('default'), isNull);
        await queue.delete(popped);
        expect(await queue.size('default'), 0);
      });

      test(
        'delayed jobs wait; released jobs come back with an attempt more',
        () async {
          await queue.push(
            payload('later'),
            queue: 'default',
            delay: const Duration(milliseconds: 200),
          );
          expect(await queue.pop('default'), isNull);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final job = (await queue.pop('default'))!;
          await queue.release(job, Duration.zero);
          final again = (await queue.pop('default'))!;
          expect(again.attempts, 2);
          expect(again.payload.uuid, job.payload.uuid);
        },
      );

      test('a job whose worker died runs again after retryAfter', () async {
        await queue.push(payload('crash'), queue: 'default');
        expect(await queue.pop('default'), isNotNull);
        expect(await queue.pop('default'), isNull);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect((await queue.pop('default'))?.attempts, 2);
      });

      test('oldestWait and clear', () async {
        expect(await queue.oldestWait('default'), isNull);
        await queue.push(payload('a'), queue: 'default');
        await queue.push(
          payload('b'),
          queue: 'default',
          delay: const Duration(minutes: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          await queue.oldestWait('default'),
          greaterThanOrEqualTo(const Duration(milliseconds: 20)),
        );
        expect(await queue.clear('default'), 2);
        expect(await queue.size('default'), 0);
      });

      test(
        'a push from another server wakes a waiting worker at once',
        () async {
          final other = RedisClient(server);
          addTearDown(other.close);
          final pusher = RedisQueue(other, prefix: prefix, engine: engine);
          final watch = Stopwatch()..start();
          final waiting = queue.waitForWork([
            'default',
          ], const Duration(seconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await pusher.push(payload('wake'), queue: 'default');
          await waiting;
          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
          expect(await queue.pop('default'), isNotNull);
        },
      );

      test('the wait ends when a delayed job is due', () async {
        await queue.push(
          payload('due'),
          queue: 'default',
          delay: const Duration(milliseconds: 300),
        );
        final watch = Stopwatch()..start();
        await queue.waitForWork(['default'], const Duration(seconds: 10));
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(await queue.pop('default'), isNotNull);
      });
    });
  }

  group('application', () {
    final apps = <Application>[];
    tearDown(() async {
      for (final app in apps) {
        await app.shutdown();
      }
      apps.clear();
    });

    Future<Application> boot([Map<String, String> env = const {}]) async {
      final app =
          Application.configure(
                basePath: Directory.systemTemp.createTempSync('redis_').path,
              )
              .withRedis()
              .withEnv({
                'APP_ENV': 'testing',
                'APP_KEY':
                    'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                'DB_DATABASE': ':memory:',
                'REDIS_URL': url,
                'REDIS_CACHE_DB': '${server.database}',
                'REDIS_PREFIX': prefix,
                'CACHE_STORE': 'redis',
                'CACHE_LIMITER': 'redis',
                'QUEUE_CONNECTION': 'redis',
                ...env,
              })
              .withMigrations(const [CreateJobsTable()])
              .withJobs([JobDefinition('ping', Ping.fromJson)])
              .create();
      await app.boot();
      await app.run(() => App.make<Migrator>().run());
      apps.add(app);
      return app;
    }

    test('cache, rate limits, the queue and the facade, from .env', () async {
      final app = await boot();
      Ping.ran.clear();
      await app.run(() async {
        expect(await Cache.remember('answer', null, () async => 42), 42);
        expect(await Cache.get<int>('answer'), 42);
        expect(Cache.store().store, isA<RedisStore>());

        final limiter = App.make<RateLimiter>();
        final hits = [
          for (var i = 0; i < 4; i++)
            (await limiter.attempt(
              'login',
              3,
              const Duration(minutes: 1),
            )).allowed,
        ];
        expect(hits, [true, true, true, false]);

        expect(Queue.manager.connection(), isA<RedisQueue>());
        final worker = QueueWorker(Queue.manager);
        final run = worker.run(
          const WorkerOptions(sleep: Duration(seconds: 30), maxJobs: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final watch = Stopwatch()..start();
        await Queue.dispatch(const Ping('redis'));
        expect(await run.timeout(const Duration(seconds: 5)), 0);
        expect(Ping.ran, ['redis']);
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

        expect(await Redis.command(['PING']), 'PONG');
      });
    });

    test(
      'tiered cache, stream queue, GCRA and serialize(), from .env',
      () async {
        final app = await boot({
          'CACHE_STORE': 'tiered',
          'QUEUE_REDIS_ENGINE': 'stream',
          'REDIS_SERIALIZER': 'php',
        });
        Ping.ran.clear();
        await app.run(() async {
          expect(Cache.store().store, isA<TieredStore>());
          await Cache.put('list', [1, 'a']);
          expect(await Cache.get<Object?>('list'), [1, 'a']);
          final cachePrefix = App.make<ConfigRepository>()
              .section<CacheConfig>()
              .prefix;
          // As Laravel's serialize() writes it.
          expect(
            await Redis.connection('cache')
                .get('${prefix}tiered:${cachePrefix}list'),
            'a:2:{i:0;i:1;i:1;s:1:"a";}',
          );

          final limiter = App.make<RateLimiter>();
          final hits = [
            for (var i = 0; i < 3; i++)
              (await limiter.attempt(
                'gcra',
                2,
                const Duration(minutes: 1),
                algorithm: RateLimitAlgorithm.gcra,
              )).allowed,
          ];
          expect(hits, [true, true, false]);

          final queue = Queue.manager.connection() as RedisQueue;
          expect(queue.engine, RedisQueueEngine.stream);
          final worker = QueueWorker(Queue.manager);
          final run = worker.run(
            const WorkerOptions(sleep: Duration(seconds: 30), maxJobs: 1),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await Queue.dispatch(const Ping('stream'));
          expect(await run.timeout(const Duration(seconds: 5)), 0);
          expect(Ping.ran, ['stream']);
        });
      },
    );

    test('a JWT revoked on one server is refused on another', () async {
      final users = <Map<String, Object?>>[];
      Application jwtApp() =>
          Application.configure(
                basePath: Directory.systemTemp.createTempSync('redis_').path,
              )
              .withRedis()
              .withEnv({
                'APP_ENV': 'testing',
                'APP_KEY':
                    'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                'DB_DATABASE': ':memory:',
                'REDIS_URL': url,
                'REDIS_CACHE_DB': '${server.database}',
                'REDIS_PREFIX': prefix,
                'CACHE_STORE': 'redis',
              })
              .withAuth((auth) => auth.jwt<_User>('jwt', _Users(users)))
              .create();
      users.add({'id': 7});
      final first = jwtApp();
      final second = jwtApp();
      await first.boot();
      await second.boot();
      apps
        ..add(first)
        ..add(second);
      final token = await first.run(
        () => Auth.jwtGuard().issue(const _User(7)),
      );
      Future<bool> accepted(Application app) => app.run(
        () => Container.current.runScoped('request', (scope) async {
          scope.put<Request>(
            Request.fake(headers: {'authorization': 'Bearer $token'}),
          );
          return await Auth.guard('jwt').user() != null;
        }),
      );
      expect(await accepted(second), isTrue);
      await first.run(() => Auth.jwtGuard().invalidate(token));
      expect(await accepted(second), isFalse);
    });
  });
}

final class _User implements Authenticatable {
  const _User(this.id);
  final int id;
  @override
  Object get authIdentifier => id;
  @override
  String get authIdentifierName => 'id';
  @override
  String? get authPassword => null;
  @override
  String get authPasswordName => 'password';
  @override
  String? get rememberToken => null;
}

final class _Users implements UserProvider<_User> {
  _Users(this.rows);
  final List<Map<String, Object?>> rows;

  @override
  Future<_User?> retrieveById(Object id) async =>
      rows.any((row) => '${row['id']}' == '$id')
      ? _User(int.parse('$id'))
      : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
