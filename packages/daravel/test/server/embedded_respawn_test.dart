// Issue #159: embedded workers that restart on purpose are not crashes,
// crashes never stop the respawning, uncaught async errors are logged, and
// an isolate-scoped queue cannot be served by several isolates.
import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Outlives its timeout and does not fail on it: the worker releases it and
/// stops for a restart (exit code 1), a clean end of the isolate.
final class Lingering extends Job {
  const Lingering();
  @override
  String get jobName => 'lingering';
  @override
  int get tries => 1000;
  @override
  Duration get timeout => const Duration(milliseconds: 1);
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) =>
      Future<void>.delayed(const Duration(milliseconds: 50));
}

/// Leaves an uncaught asynchronous error behind, then finishes.
final class Stray extends Job {
  const Stray();
  @override
  String get jobName => 'stray';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// Hands out one [job] per isolate, then nothing.
final class OneJob implements QueueDriver {
  OneJob(this.job);
  final Job job;
  bool _given = false;

  @override
  String get name => 'one';
  @override
  StateScope get scope => StateScope.cluster;
  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) async => 1;
  @override
  Future<QueuedJob?> pop(String queue) async {
    if (_given) {
      return null;
    }
    _given = true;
    final payload = JobPayload.forJob(job);
    return QueuedJob(
      id: 1,
      queue: queue,
      payload: payload,
      attempts: 1,
      raw: payload.encode(),
    );
  }

  @override
  Future<void> release(QueuedJob job, Duration delay) async {}
  @override
  Future<void> delete(QueuedJob job) async {}
  @override
  Future<int> size(String queue) async => 0;
  @override
  Future<Duration?> oldestWait(String queue) async => null;
  @override
  Future<int> clear(String queue) async => 0;
}

ApplicationBuilder _base(String connection) =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': connection,
        })
        .withLogLevel(LogLevel.error)
        .withJobs([
          JobDefinition('lingering', (_) => const Lingering()),
          JobDefinition('stray', (_) => const Stray()),
        ]);

/// Top-level: its worker restarts after its one job, every time.
Application restartingApp() =>
    _base('one')
        .withQueueDriver('one', (_) => OneJob(const Lingering()))
        .create();

/// Top-level: fails to boot, every time.
Application crashingApp() => _base('sync')
    .withConfigCheck(
      (env, config) => [
        const ConfigIssue(ConfigIssueLevel.error, 'cannot boot on purpose'),
      ],
    )
    .create();

/// Top-level: a `JobProcessed` listener of its worker throws from a
/// fire-and-forget future.
Application strayApp() =>
    _base('one')
        .withQueueDriver('one', (_) => OneJob(const Stray()))
        .withEvents((events) {
          events.listen<JobProcessed>((_) {
            unawaited(Future<void>(() => throw StateError('stray listener')));
          });
        })
        .create();

Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'a worker that restarts on purpose is started again, uncounted',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final log = MemoryHandler();
      final embedded = EmbeddedWorkers(
        restartingApp,
        roles: const [EmbeddedRole.queue],
        logger: Logger(handlers: [log]),
        crashDelay: (_) => const Duration(minutes: 5),
      );
      await embedded.start();
      addTearDown(embedded.stop);
      await until(
        () => log.matching(LogLevel.info, 'starting it again').length >= 8,
        'eight restarts',
      );
      expect(log.matching(LogLevel.error), isEmpty);
    },
  );

  test(
    'a role that keeps crashing is started again, with errors logged',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final log = MemoryHandler();
      final delays = <int>[];
      final embedded = EmbeddedWorkers(
        crashingApp,
        roles: const [EmbeddedRole.queue],
        logger: Logger(handlers: [log]),
        crashDelay: (crashes) {
          delays.add(crashes);
          return Duration.zero;
        },
      );
      await embedded.start();
      addTearDown(embedded.stop);
      await until(() => delays.length >= 8, 'eight crashes');
      expect(delays.take(8), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(
        log.matching(LogLevel.error, 'crashed 6 times in a minute'),
        isNotEmpty,
      );
      expect(EmbeddedWorkers.defaultCrashDelay(3), const Duration(seconds: 3));
      expect(EmbeddedWorkers.defaultCrashDelay(6), const Duration(minutes: 1));
    },
  );

  test(
    'an uncaught async error in an embedded isolate is logged, not fatal',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final log = MemoryHandler();
      final embedded = EmbeddedWorkers(
        strayApp,
        roles: const [EmbeddedRole.queue],
        logger: Logger(handlers: [log]),
        crashDelay: (_) => Duration.zero,
      );
      await embedded.start();
      addTearDown(embedded.stop);
      // The stray error is logged in the isolate, which keeps running.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(log.matching(LogLevel.error), isEmpty);
      expect(log.matching(LogLevel.info, 'starting it again'), isEmpty);
    },
  );

  group('serve refuses a queue of one isolate', () {
    for (final options in const [
      ServeOptions(isolates: 2, port: 0),
      ServeOptions(embedQueue: true, port: 0),
    ]) {
      test('isolates: ${options.isolates}, embedQueue: '
          '${options.embedQueue}', () async {
        final app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': 'memory',
            })
            .create();
        await app.boot();
        addTearDown(app.shutdown);
        await expectLater(
          app.serve(options: options),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('QUEUE_CONNECTION=memory'),
            ),
          ),
        );
      });
    }
  });
}
