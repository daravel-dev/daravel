import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Mail extends Job {
  const Mail();
  @override
  String get jobName => 'mail';
  @override
  Map<String, Object?> toJson() => const {'to': 'a@example.com'};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// [env] `BASE_PATH` is the test's own directory: the default signal
/// store is a file cache under it, which test files running in parallel
/// would otherwise share (a status written by one seen by another).
Application dashboardApp([Map<String, String> env = const {}]) =>
    Application.configure(
          basePath: env['BASE_PATH'] ?? Directory.systemTemp.path,
        )
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'database',
          'HORIZON_ALLOW_SQLITE': 'true',
          ...env,
        })
        .withLogLevel(LogLevel.critical)
        .withMigrations(const [CreateJobsTable()])
        .withJobs([JobDefinition('mail', (_) => const Mail())])
        .withHorizon(
          createApp: dashboardApp,
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a')],
              maxProcesses: 1,
            ),
          ],
        )
        .create();

void main() {
  late Application app;
  late TestClient client;

  late Directory base;

  Future<void> boot([Map<String, String> env = const {}]) async {
    base = Directory.systemTemp.createTempSync('horizon_routes_');
    app = dashboardApp({'BASE_PATH': base.path, ...env});
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  }

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<void> record(
    String uuid,
    String status, {
    List<String> tags = const [],
    String name = 'mail',
  }) => app.run(
    () => App.make<CoordinatorChannel>().call('horizon', 'record', {
      'job': jsonEncode(
        RecordedJob(
          uuid: uuid,
          name: name,
          queue: 'a',
          status: status,
          at: Clock.now().millisecondsSinceEpoch,
          tags: tags,
          durationMs: 12,
          error: status == 'failed' ? 'StateError: boom' : null,
        ).toJson(),
      ),
    }),
  );

  test('stats: Laravel Horizon\'s fields', () async {
    await boot();
    await record('c1', 'completed');
    await record('f1', 'failed');
    final response = await client.get('/horizon/api/stats');
    expect(response.status, 200, reason: response.body);
    final stats = response.jsonMap;
    expect(stats['status'], 'inactive');
    expect(stats['jobsPerMinute'], 2);
    expect(stats['recentJobs'], 2);
    expect(stats['failedJobs'], 1);
    expect(stats['processes'], 0);
    expect((stats['wait']! as Map).keys, ['database:a']);
    expect(
      (stats['periods']! as Map).keys,
      containsAll(['recentJobs', 'failedJobs']),
    );
  });

  test('recent completed, silenced and failed jobs; one by uuid', () async {
    await boot();
    await record('c1', 'completed');
    await record('s1', 'silenced');
    await record('f1', 'failed');
    for (final (status, uuid) in [
      ('completed', 'c1'),
      ('silenced', 's1'),
      ('failed', 'f1'),
    ]) {
      final list =
          (await client.get('/horizon/api/jobs/$status')).jsonMap['jobs']!
              as List<Object?>;
      expect([for (final j in list) (j! as Map)['uuid']], [uuid]);
    }
    expect((await client.get('/horizon/api/jobs/c1')).jsonMap['name'], 'mail');
    expect((await client.get('/horizon/api/jobs/none')).status, 404);
  });

  test('a negative starting_at lists from the start', () async {
    // The process store skipped a negative count (a RangeError, 500); the
    // database store's query already treats it as 0.
    await boot();
    await record('c1', 'completed');
    await record('c2', 'completed');
    for (final at in ['-10', '-1', '0', 'x']) {
      final response = await client.get(
        '/horizon/api/jobs/completed?starting_at=$at',
      );
      expect(response.status, 200, reason: at);
      expect(response.jsonMap['jobs'], hasLength(2), reason: at);
    }
  });

  test('monitoring: add a tag, list its jobs, remove it', () async {
    await boot();
    expect(
      (await client.post(
        '/horizon/api/monitoring',
        json: {'tag': 'User:1'},
      )).status,
      204,
    );
    await record('t1', 'completed', tags: ['User:1']);
    expect((await client.get('/horizon/api/monitoring')).json, [
      {'tag': 'User:1', 'count': 1},
    ]);
    final tagged =
        (await client.get('/horizon/api/monitoring/User:1')).jsonMap['jobs']!
            as List<Object?>;
    expect(tagged, hasLength(1));
    expect((await client.delete('/horizon/api/monitoring/User:1')).status, 204);
    expect((await client.get('/horizon/api/monitoring')).json, isEmpty);
    expect(
      (await client.post('/horizon/api/monitoring', json: {'tag': ' '})).status,
      422,
    );
  });

  test('metrics after a snapshot', () async {
    await boot();
    await record('m1', 'completed');
    await app.run(
      () => App.make<CoordinatorChannel>().call('horizon', 'snapshot', {}),
    );
    expect((await client.get('/horizon/api/metrics/jobs')).json, ['mail']);
    expect((await client.get('/horizon/api/metrics/queues')).json, ['a']);
    final snapshots =
        (await client.get('/horizon/api/metrics/jobs/mail')).json!
            as List<Object?>;
    expect((snapshots.single! as Map)['count'], 1);
  });

  test('pending jobs from the queue, with their payload as a string', () async {
    await boot();
    await app.run(() => Queue.push(const Mail(), queue: 'a'));
    final jobs =
        (await client.get('/horizon/api/jobs/pending')).jsonMap['jobs']!
            as List<Object?>;
    final job = jobs.single! as Map;
    expect(job['queue'], 'a');
    expect(job['connection'], 'database');
  });

  test('a failed job: detail from failed_jobs, retry and retry-all', () async {
    await boot();
    final uuids = <String>[];
    await app.run(() async {
      final failed = App.make<QueueManager>().processor.failedJobs;
      for (final uuid in ['x1', 'x2']) {
        uuids.add(uuid);
        await failed.log(
          connection: 'database',
          queue: 'a',
          payload: JobPayload.forJob(const Mail(), uuid: uuid).encode(),
          exception: 'StateError: boom\n#0 main',
        );
      }
    });
    final detail = (await client.get('/horizon/api/jobs/failed/x1')).jsonMap;
    expect(detail['payload'], isA<String>());
    expect(detail['exception'], startsWith('StateError: boom'));
    expect((await client.get('/horizon/api/jobs/failed/nope')).status, 404);

    expect(
      (await client.post('/horizon/api/jobs/retry/x1')).jsonMap['retried'],
      'x1',
    );
    expect((await client.post('/horizon/api/jobs/retry/x1')).status, 404);
    expect(
      (await client.post('/horizon/api/jobs/retry-all')).jsonMap['retried'],
      ['x2'],
    );
    expect(await app.run(() => Queue.size('a')), 2);
  });

  test('stream: server-sent events that end when the server drains', () async {
    await boot();
    app.drainSignal.signal();
    final response = await client.get('/horizon/api/stream');
    expect(response.status, 200);
    expect(response.headers['content-type'], 'text/event-stream');
    expect(response.body, contains('retry: '));
  });

  test('outside local and testing, every endpoint needs middleware', () async {
    await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:${base64.encode(List.filled(32, 7))}',
    });
    for (final (method, path) in [
      ('GET', '/horizon/api/stats'),
      ('GET', '/horizon/api/jobs/failed'),
      ('POST', '/horizon/api/jobs/retry-all'),
      ('POST', '/horizon/api/monitoring'),
      ('DELETE', '/horizon/api/monitoring/x'),
    ]) {
      final response = await client.send(method, path);
      expect(response.status, 403, reason: '$method $path');
    }
  }, tags: ['security']);

  test('HORIZON_ENABLED=false: 404', () async {
    await boot({'HORIZON_ENABLED': 'false'});
    expect((await client.get('/horizon/api/stats')).status, 404);
  });

  test('route names are Laravel Horizon\'s', () async {
    await boot();
    final names = {for (final route in app.router.routes) ?route.routeName};
    expect(
      names,
      containsAll([
        'horizon.stats.index',
        'horizon.workload.index',
        'horizon.masters.index',
        'horizon.monitoring.index',
        'horizon.monitoring.store',
        'horizon.monitoring-tag.paginate',
        'horizon.monitoring-tag.destroy',
        'horizon.jobs-metrics.index',
        'horizon.jobs-metrics.show',
        'horizon.queues-metrics.index',
        'horizon.queues-metrics.show',
        'horizon.pending-jobs.index',
        'horizon.completed-jobs.index',
        'horizon.silenced-jobs.index',
        'horizon.failed-jobs.index',
        'horizon.failed-jobs.show',
        'horizon.retry-jobs.show',
        'horizon.jobs.show',
      ]),
    );
  });

  test('the page: one CSP nonce for its inline style and script, a tab per '
      'path, 404 for an unknown tab', () async {
    await boot();
    final page = await client.get('/horizon');
    expect(page.status, 200);
    final csp = page.headers['content-security-policy']!;
    final nonce = RegExp(r"'nonce-([^']+)'").firstMatch(csp)![1]!;
    expect(page.body, contains('<script nonce="$nonce">'));
    expect(page.body, contains('<style nonce="$nonce">'));
    expect(csp, contains("default-src 'none'"));
    expect(page.headers['x-frame-options'], 'DENY');
    expect(page.headers['cache-control'], 'no-store');
    expect(page.body, contains('data-tab="dashboard"'));
    final other = await client.get('/horizon');
    expect(
      other.headers['content-security-policy'],
      isNot(csp),
      reason: 'a fresh nonce per response',
    );
    final failed = await client.get('/horizon/failed');
    expect(failed.status, 200);
    expect(failed.body, contains('data-tab="failed"'));
    expect((await client.get('/horizon/nope')).status, 404);
  });

  test('the page needs middleware outside local and testing too', () async {
    await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:${base64.encode(List.filled(32, 7))}',
    });
    expect((await client.get('/horizon')).status, 403);
    expect((await client.get('/horizon/failed')).status, 403);
  }, tags: ['security']);

  test(
    'a status that cannot be read, or of another shape, is inactive',
    () async {
      await boot();
      final signals = app.container.make<QueueManager>().signalStore!;
      for (final raw in [
        'not json',
        jsonEncode({
          'state': 3,
          'supervisors': [1, 2],
        }),
        jsonEncode([1, 2]),
      ]) {
        await app.run(
          () => signals.store.forever(HorizonSignals.statusKey('horizon'), raw),
        );
        for (final path in ['stats', 'workload', 'masters']) {
          travel(const Duration(seconds: 2));
          final response = await client.get('/horizon/api/$path');
          expect(response.status, 200, reason: '$raw: $path ${response.body}');
        }
        expect(
          (await client.get('/horizon/api/stats')).jsonMap['status'],
          'inactive',
        );
      }
    },
  );

  test('a snapshot that fails fails every request waiting on it, none '
      'hangs', () async {
    await boot();
    // The store answers rates of the wrong shape: the snapshot throws.
    final channel = app.container.make<CoordinatorChannel>();
    (channel as LocalCoordinatorChannel).coordinator.register(_BadRates());
    final answers = await Future.wait([
      client.get('/horizon/api/stats'),
      client.get('/horizon/api/workload'),
      client.get('/horizon/api/stats'),
    ]).timeout(const Duration(seconds: 5));
    expect(answers.map((r) => r.status), [500, 500, 500]);
  });

  test('stats and workload read each queue once a second, however many '
      'clients ask', () async {
    freezeTime();
    final queue = _CountingQueue();
    base = Directory.systemTemp.createTempSync('horizon_routes_');
    app = _countingApp(base.path, queue);
    await app.boot();
    client = TestClient(app);
    final other = TestClient(app);
    for (var tick = 1; tick <= 2; tick++) {
      for (final c in [client, other]) {
        expect((await c.get('/horizon/api/stats')).status, 200);
        expect((await c.get('/horizon/api/workload')).status, 200);
      }
      // Two queues, read once this tick.
      expect(queue.sizes, tick * 2);
      travel(const Duration(seconds: 1));
    }
    // Two clients at the same moment, as the last snapshot expires: one
    // read of each queue between them.
    final both = await Future.wait([
      client.get('/horizon/api/stats'),
      other.get('/horizon/api/workload'),
    ]);
    expect(both.map((r) => r.status), [200, 200]);
    expect(queue.sizes, 3 * 2);
  });
}

/// The dashboard over [queue] (two queues), in [base].
Application _countingApp(String base, _CountingQueue queue) =>
    Application.configure(basePath: base)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'counting',
        })
        .withLogLevel(LogLevel.critical)
        .withQueueDriver('counting', (_) => queue)
        .withHorizon(
          createApp: dashboardApp,
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a'), QueueName('b')],
              maxProcesses: 1,
            ),
          ],
        )
        .create();

/// A [MemoryQueue] counting the calls of [size].
final class _CountingQueue implements QueueDriver {
  final MemoryQueue _inner = MemoryQueue();
  int sizes = 0;

  @override
  String get name => 'counting';

  @override
  StateScope get scope => _inner.scope;

  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) => _inner.push(payload, queue: queue, delay: delay);

  @override
  Future<QueuedJob?> pop(String queue) => _inner.pop(queue);

  @override
  Future<void> release(QueuedJob job, Duration delay) =>
      _inner.release(job, delay);

  @override
  Future<void> delete(QueuedJob job) => _inner.delete(job);

  @override
  Future<int> size(String queue) {
    sizes++;
    return _inner.size(queue);
  }

  @override
  Future<Duration?> oldestWait(String queue) => _inner.oldestWait(queue);

  @override
  Future<int> clear(String queue) => _inner.clear(queue);
}

/// Horizon's store, answering `rates` with a run time that is not a
/// number.
final class _BadRates implements CoordinatorService {
  @override
  String get name => HorizonService.serviceName;

  @override
  Object? handle(String op, Map<String, Object?> args) => switch (op) {
    'rates' => jsonEncode({'avg_ms': 'not a number'}),
    _ => null,
  };

  @override
  Map<String, Object?> stats() => const {};
}
