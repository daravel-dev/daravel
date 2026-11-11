import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final List<String> log = [];

/// A job with each retry setting a timeout looks at.
final class Timed extends Job {
  const Timed({
    this.label = 'timed',
    this.maxTries = 3,
    this.fails = false,
    this.exceptions,
    this.until,
  });

  factory Timed.fromJson(Map<String, Object?> json) =>
      Timed(label: json['label']! as String);

  final String label;
  final int maxTries;
  final bool fails;
  final int? exceptions;
  final Duration? until;

  @override
  String get jobName => 'timed';

  @override
  int get tries => maxTries;

  @override
  bool get failOnTimeout => fails;

  @override
  int? get maxExceptions => exceptions;

  @override
  Duration? get retryUntil => until;

  @override
  Map<String, Object?> toJson() => {'label': label};

  @override
  Future<void> handle(JobContext ctx) async {
    log.add('ran:$label');
    if (label == 'own-timeout') {
      // The handler's own timeout (an HTTP client's), not the job's.
      throw TimeoutException('upstream', const Duration(seconds: 1));
    }
  }

  @override
  Future<void> failed(Object error, StackTrace stackTrace) async =>
      log.add('failed:$label:${error.runtimeType}');
}

final class OwnTimeoutFails extends Job {
  const OwnTimeoutFails();

  @override
  String get jobName => 'own';

  @override
  int get tries => 3;

  @override
  bool get failOnTimeout => true;

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {
    log.add('ran:own');
    throw TimeoutException('upstream', const Duration(seconds: 1));
  }
}

void main() {
  late Application app;

  setUp(() async {
    log.clear();
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_fot_')
                  .path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': 'database',
            })
            .withLogLevel(LogLevel.critical)
            .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
            .withJobs([
              JobDefinition('timed', Timed.fromJson),
              JobDefinition('own', (_) => const OwnTimeoutFails()),
            ])
            .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });
  tearDown(() => app.shutdown());

  group('failsAfterTimeout (the rule of Laravel\'s timeout handler)', () {
    Future<bool> decide(Job job, int attempts, {int? tries}) => app.run(
      () => Queue.manager.processor.failsAfterTimeout(
        JobPayload.forJob(job),
        attempts,
        tries: tries,
      ),
    );

    test('tries left and nothing else: tried again', () async {
      expect(await decide(const Timed(), 1), isFalse);
      expect(await decide(const Timed(), 2), isFalse);
    });

    test('its tries used up, or --tries overriding them', () async {
      expect(await decide(const Timed(), 3), isTrue);
      expect(await decide(const Timed(), 1, tries: 1), isTrue);
    });

    test('retryUntil passed', () async {
      expect(await decide(const Timed(until: Duration.zero), 1), isTrue);
      expect(await decide(const Timed(until: Duration(hours: 1)), 1), isFalse);
    });

    test('maxExceptions: this timeout is the last one allowed', () async {
      const job = Timed(exceptions: 2, maxTries: 0);
      final payload = JobPayload.forJob(job);
      Future<bool> once() =>
          app.run(() => Queue.manager.processor.failsAfterTimeout(payload, 1));
      expect(await once(), isFalse, reason: 'one of two');
      expect(await once(), isTrue, reason: 'two of two');
    });

    test('failOnTimeout', () async {
      expect(await decide(const Timed(fails: true), 1), isTrue);
    });
  });

  group('WorkerOptions.failBeforeRun', () {
    Future<void> work(WorkerOptions options) =>
        app.run(() => QueueWorker(Queue.manager).run(options));

    test('an error fails the job without running it: failed_jobs, its '
        'failed() hook and JobFailed', () async {
      await app.run(() => Queue.push(const Timed(label: 'marked')));
      final failedEvents = <JobFailed>[];
      app.container.make<EventDispatcher>().listen<JobFailed>(failedEvents.add);
      await work(
        WorkerOptions(
          stopWhenEmpty: true,
          failBeforeRun: (job) =>
              TimeoutExceededException(job.payload.displayName),
        ),
      );
      expect(log, ['failed:marked:TimeoutExceededException']);
      final failed = await app.run(
        () => Queue.manager.processor.failedJobs.all(),
      );
      expect(failed.single.exception, contains('Timed has timed out.'));
      expect(failedEvents.single.error, isA<TimeoutExceededException>());
      expect(await app.run(() => Queue.connection().size('default')), 0);
    });

    test('null runs the job; an error thrown by it is logged and the job '
        'runs', () async {
      await app.run(() async {
        await Queue.push(const Timed(label: 'a'));
        await Queue.push(const Timed(label: 'b'));
      });
      await work(
        WorkerOptions(
          stopWhenEmpty: true,
          failBeforeRun: (job) async =>
              (job.payload.data['label'] == 'b') ? throw StateError('x') : null,
        ),
      );
      expect(log, ['ran:a', 'ran:b']);
    });
  });

  test("the handler's own TimeoutException is an ordinary failure: retried, "
      'not failed as a timeout of a failOnTimeout job', () async {
    await app.run(() => Queue.push(const OwnTimeoutFails()));
    await app.run(
      () =>
          QueueWorker(Queue.manager)
              .runNextJob(Queue.connection(), const WorkerOptions()),
    );
    expect(log, ['ran:own']);
    expect(
      await app.run(() => Queue.manager.processor.failedJobs.all()),
      isEmpty,
    );
    expect(await app.run(() => Queue.connection().size('default')), 1);
  });

  test("the worker's timer fails a failOnTimeout job with "
      'TimeoutExceededException, a TimeoutException too', () {
    final error = TimeoutExceededException('Sync', const Duration(seconds: 2));
    expect(error, isA<TimeoutException>());
    expect(error.message, 'Sync has timed out.');
    expect(error.duration, const Duration(seconds: 2));
    expect('$error', 'TimeoutExceededException: Sync has timed out.');
  });
}
