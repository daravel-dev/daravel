import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

final class Note extends Job {
  const Note();
  @override
  String get jobName => 'note';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// Always fails: on `sync`, retried, it fails again at once.
final class Doomed extends Job {
  const Doomed();

  static int runs = 0;

  @override
  String get jobName => 'doomed';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    runs++;
    throw StateError('doomed');
  }
}

/// A failed job provider without pages (a third party's): only
/// [FailedJobProvider].
final class _NoPages implements FailedJobProvider {
  final MemoryFailedJobProvider _inner = MemoryFailedJobProvider();

  @override
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  }) => _inner.log(
    connection: connection,
    queue: queue,
    payload: payload,
    exception: exception,
  );

  @override
  Future<List<FailedJob>> all() => _inner.all();

  @override
  Future<FailedJob?> find(Object id) => _inner.find(id);

  @override
  Future<bool> forget(Object id) => _inner.forget(id);

  @override
  Future<int> flush() => _inner.flush();

  @override
  Future<int> prune(Duration olderThan) => _inner.prune(olderThan);
}

/// `queue:retry` before and after it moved onto `QueueManager.retryFailed`
/// (Blueprint #134 H4a): the same lines, the same jobs pushed back.
void main() {
  late Directory dir;
  late String db;

  Application retryApp() => Application.configure(basePath: dir.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': db,
        'QUEUE_CONNECTION': 'database',
      })
      .withLogLevel(LogLevel.critical)
      .withMigrations(const [CreateJobsTable()])
      .withJobs([JobDefinition('note', (_) => const Note())])
      .create();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('queue_retry_');
    db = '${dir.path}${Platform.pathSeparator}app.sqlite';
    final app = retryApp();
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      final failed = App.make<QueueManager>().processor.failedJobs;
      for (final uuid in ['uuid-a', 'uuid-b']) {
        await failed.log(
          connection: 'database',
          queue: 'mail',
          payload: JobPayload.forJob(const Note(), uuid: uuid).encode(),
          exception: 'StateError: boom',
        );
      }
    });
    await app.shutdown();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<(int, String)> retry(List<String> args) async {
    // ignore: close_sinks (stdout of the zone, never opened)
    final out = _Capture();
    final code = await IOOverrides.runZoned(
      () => DartisanRunner(retryApp).execute(['queue:retry', ...args]),
      stdout: () => out,
    );
    return (code, '${out.buffer}');
  }

  Future<(int, int)> counts() async {
    final app = retryApp();
    await app.boot();
    try {
      return await app.run(
        () async => (
          (await App.make<QueueManager>().processor.failedJobs.all()).length,
          await App.make<QueueManager>().connection().size('mail'),
        ),
      );
    } finally {
      await app.shutdown();
    }
  }

  test('one job by uuid, then the rest with all; unknown ids say so', () async {
    var (code, text) = await retry(['uuid-a']);
    expect(code, 0);
    expect(
      text,
      'The failed job [uuid-a] has been pushed back onto the queue.\n',
    );
    expect(await counts(), (1, 1));

    (code, text) = await retry(['nope']);
    expect(text, 'No failed jobs matched.\n');

    (code, text) = await retry(['all']);
    expect(
      text,
      'The failed job [uuid-b] has been pushed back onto the queue.\n',
    );
    expect(await counts(), (0, 2));
  });

  test('all goes past an unreadable payload, which stays: exit 1', () async {
    final app = retryApp();
    await app.boot();
    await app.run(() async {
      final failed = App.make<QueueManager>().processor.failedJobs;
      await failed.log(
        connection: 'database',
        queue: 'mail',
        payload: '{"job":"note","uuid":5}',
        exception: 'StateError: boom',
      );
      await failed.log(
        connection: 'database',
        queue: 'mail',
        payload: JobPayload.forJob(const Note(), uuid: 'uuid-c').encode(),
        exception: 'StateError: boom',
      );
    });
    await app.shutdown();
    final (code, text) = await retry(['all']);
    expect(code, 1, reason: 'one left behind');
    expect(
      text,
      'The failed job [uuid-a] has been pushed back onto the queue.\n'
      'The failed job [uuid-b] has been pushed back onto the queue.\n'
      'The failed job [uuid-c] has been pushed back onto the queue.\n',
    );
    expect(await counts(), (1, 3), reason: 'the unreadable one stays');
  });

  test('--queue retries every failed job of that queue', () async {
    final (code, text) = await retry(['--queue=other']);
    expect(code, 0);
    expect(text, 'No failed jobs matched.\n');
    final (code2, _) = await retry(['--queue=mail']);
    expect(code2, 0);
    expect(await counts(), (0, 2));
  });

  test('a provider without pages is read once: on sync, a job failing '
      'again at once does not keep the passes going', () async {
    Doomed.runs = 0;
    final container = Container();
    final events = EventDispatcher();
    final registry = JobRegistry([
      JobDefinition('doomed', (_) => const Doomed()),
    ]);
    final failed = _NoPages();
    final manager = QueueManager(
      config: const QueueConfig(),
      registry: registry,
      events: events,
      container: container,
      processor: JobProcessor(
        registry: registry,
        events: events,
        failedJobs: failed,
        container: container,
      ),
    )..extend('sync', SyncQueue.new);
    for (var i = 0; i < 5; i++) {
      await failed.log(
        connection: 'sync',
        queue: 'default',
        payload: JobPayload.forJob(const Doomed(), uuid: 'd$i').encode(),
        exception: 'StateError: doomed',
      );
    }
    // A pass budget of nothing: each pass would stop after one job and
    // the next read them all again, the new failures included.
    final totals = await QueueRetryCommand.retryAll(
      manager,
      passBudget: Duration.zero,
    ).timeout(const Duration(seconds: 20));
    expect(totals, (retried: 5, skipped: 0));
    expect(Doomed.runs, 5, reason: 'each of the 5 once');
    expect(await failed.all(), hasLength(5), reason: 'their new failures');
  });
}

/// Collects what a command prints.
final class _Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
