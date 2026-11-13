import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

final String _temp = '${Directory.systemTemp.path}${Platform.pathSeparator}';

/// What the worker isolates read: the Redis queue engine of the test
/// running (they cannot be handed arguments).
final String _engineMarker = '${_temp}horizon_redis_engine_$pid.txt';
final String _dbPath = '${_temp}horizon_redis_quarantine_$pid.sqlite';

final class Boom extends Job {
  const Boom();
  factory Boom.fromJson(Map<String, Object?> json) => const Boom();

  @override
  String get jobName => 'boom';

  @override
  int get tries => 3;

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {
    // Brings its worker down: the master counts the crash, takes the job
    // back and, after two, quarantines it.
    Isolate.current.kill(priority: Isolate.immediate);
    await Completer<void>().future;
  }
}

/// The application of the master and its workers: a Redis queue.
Application redisApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': _dbPath,
          'QUEUE_CONNECTION': 'redis',
          'QUEUE_RETRY_AFTER': '90s',
          'REDIS_URL': Platform.environment['DARAVEL_TEST_REDIS'] ?? '',
          'REDIS_PREFIX': 'horizon-quarantine-$pid-',
          'QUEUE_REDIS_ENGINE': File(_engineMarker).existsSync()
              ? File(_engineMarker).readAsStringSync()
              : 'list',
          'CACHE_STORE': 'file',
        })
        .withLogLevel(LogLevel.error)
        .withRedis()
        .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
        .withJobs([JobDefinition('boom', Boom.fromJson)])
        .create();

/// `daravel_horizon` quarantines a job that crashed two workers by deleting
/// it while it waits (after the reclaim): on a real Redis queue, the job
/// leaves the queue, list and stream engines alike. With
/// `DARAVEL_TEST_REDIS`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'quarantine on Redis (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }

  for (final engine in RedisQueueEngine.values) {
    group(engine.name, () {
      late Application app;
      late Coordinator coordinator;
      final events = <(String, Map<String, Object?>)>[];

      setUp(() async {
        events.clear();
        File(_engineMarker).writeAsStringSync(engine.name);
        if (File(_dbPath).existsSync()) {
          File(_dbPath).deleteSync();
        }
        coordinator = createStandardCoordinator()..register(HorizonService());
        app = redisApp();
        await app.boot();
        await app.run(() async {
          await App.make<Migrator>().run();
          await (Queue.connection() as RedisQueue).clear('a');
        });
      });

      tearDown(() async {
        await app.run(() => (Queue.connection() as RedisQueue).clear('a'));
        await app.shutdown();
        for (final path in [_engineMarker, _dbPath]) {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // A worker may still hold it; the temporary directory's own.
          }
        }
      });

      test(
        'a job that brings its worker down twice is quarantined and leaves '
        'the queue',
        timeout: const Timeout(Duration(minutes: 2)),
        () async {
          await app.run(() => Queue.push(const Boom(), queue: 'a'));
          final m = HorizonMaster(
            redisApp,
            HorizonConfig(
              plans: const [
                SupervisorPlan(
                  name: SupervisorName('s'),
                  connection: 'redis',
                  queues: [QueueName('a')],
                  balance: BalanceStrategy.off,
                  maxProcesses: 1,
                  sleep: Duration(milliseconds: 50),
                ),
              ],
              heartbeat: const Duration(milliseconds: 100),
            ),
            driver: (connection) =>
                app.container.make<QueueManager>().connection(connection),
            logger: Logger(minimumLevel: LogLevel.critical),
            coordinator: coordinator.listen(),
            store: LocalCoordinatorChannel(coordinator),
            failedJobs: app.container.make<QueueManager>().processor.failedJobs,
            onEvent: (event, data) => events.add((event, data)),
            crashDelay: (_) => const Duration(milliseconds: 50),
          );
          addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
          await m.start();
          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (!events.any((e) => e.$1 == 'JobQuarantined')) {
            if (DateTime.now().isAfter(deadline)) {
              fail('no quarantine: ${events.map((e) => e.$1).toList()}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final failed = await app.run(
            () => App.make<QueueManager>().processor.failedJobs.all(),
          );
          expect(failed, hasLength(1));
          expect(failed.single.exception, contains('JobQuarantinedException'));
          expect(
            await app.run(() => Queue.size('a')),
            0,
            reason:
                'the waiting job left the list or stream, not only its '
                'hash',
          );
          await m.stop(timeout: const Duration(seconds: 20));
        },
      );
    });
  }
}
