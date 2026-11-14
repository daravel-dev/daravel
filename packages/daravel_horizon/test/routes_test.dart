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

/// A job whose data holds a password, for the redaction of payloads.
final class Signup extends Job {
  const Signup();
  @override
  String get jobName => 'signup';
  @override
  Map<String, Object?> toJson() => const {
    'email': 'ana@example.com',
    'password': 'hunter2',
  };
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// [env] `BASE_PATH` is the test's own directory: the default signal
/// store is a file cache under it, which test files running in parallel
/// would otherwise share (a status written by one seen by another).
/// `TEST_QUEUES` lists the supervisor's queues (`a` by default).
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
        // The application's own route, for HORIZON_PATH=/.
        .withRouting(web: (router) => router.get('/about', (_) => 'about'))
        .withHorizon(
          createApp: dashboardApp,
          plans: [
            SupervisorPlan(
              name: const SupervisorName('s'),
              queues: [
                for (final queue in (env['TEST_QUEUES'] ?? 'a').split(','))
                  QueueName(queue),
              ],
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

  // Outside local the dashboard needs a gate or a callback, in tests too;
  // the security tests below close it again.
  setUp(() => HorizonDashboard.auth((Request request) => true));

  tearDown(() async {
    HorizonDashboard.auth(null);
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

  test('pending jobs page with starting_at across the queues', () async {
    await boot({'TEST_QUEUES': 'a,b'});
    await app.run(() async {
      for (final queue in ['a', 'a', 'a', 'b', 'b']) {
        await Queue.push(const Mail(), queue: queue);
      }
    });
    Future<List<String>> page(String query) async => [
      for (final job
          in (await client.get('/horizon/api/jobs/pending?$query'))
                  .jsonMap['jobs']!
              as List<Object?>)
        '${(job! as Map)['queue']}${(job as Map)['id']}',
    ];
    expect(await page(''), ['a1', 'a2', 'a3', 'b4', 'b5']);
    expect(await page('starting_at=1&limit=2'), ['a2', 'a3']);
    expect(await page('starting_at=2&limit=2'), ['a3', 'b4']);
    expect(await page('starting_at=3'), ['b4', 'b5']);
    expect(await page('starting_at=4'), ['b5']);
    expect(await page('starting_at=5'), isEmpty);
    expect(await page('starting_at=1000000000'), isEmpty);
  });

  test('workload: the processes on each queue and its wait, from the '
      "master's status", () async {
    await boot();
    await app.run(() async {
      await Queue.push(const Mail(), queue: 'a');
      await Queue.push(const Mail(), queue: 'a');
    });
    for (var i = 0; i < 4; i++) {
      await record('c$i', 'completed');
    }
    // The shape HorizonMaster.status() publishes: a worker's queues are
    // the comma-separated list it was assigned.
    final signals = app.container.make<QueueManager>().signalStore!;
    await app.run(
      () => signals.store.forever(
        HorizonSignals.statusKey('horizon'),
        jsonEncode({
          'state': 'running',
          'at': DateTime.now().millisecondsSinceEpoch,
          'supervisors': {
            's': [
              {'name': 'w1', 'queues': 'a', 'processed': 4, 'busy': false},
            ],
          },
        }),
      ),
    );
    final workload =
        (await client.get('/horizon/api/workload')).json! as List<Object?>;
    final a = workload.single! as Map;
    expect(a['name'], 'a');
    expect(a['length'], 2);
    expect(a['processes'], 1);
    expect(a['wait'], isNotNull, reason: 'two jobs of 12 ms on one worker');
  });

  test('payloads leave without their hidden context, the rest redacted '
      'as in the logs', () async {
    await boot();
    await app.run(() async {
      Context.add('trace', 't-visible');
      Context.addHidden('tenant_key', 'hidden-value');
      await Queue.push(const Signup(), queue: 'a');
      await App.make<QueueManager>().processor.failedJobs.log(
        connection: 'database',
        queue: 'a',
        payload: JobPayload.forJob(const Signup(), uuid: 'd1').encode(),
        exception: 'StateError: boom',
      );
      // A job Laravel pushed onto the shared table: its Context under
      // Laravel's own key.
      await App.make<QueueManager>().processor.failedJobs.log(
        connection: 'database',
        queue: 'a',
        payload: jsonEncode({
          'uuid': 'l1',
          'displayName': r'App\Jobs\Signup',
          'data': {'command': 'O:8:"stdClass":0:{}'},
          'illuminate:log:context': {
            'data': {'trace': 's:9:"t-visible";'},
            'hidden': {'tenant_key': 's:12:"hidden-value";'},
          },
        }),
        exception: 'StateError: boom',
      );
    });
    final pending =
        ((await client.get('/horizon/api/jobs/pending')).jsonMap['jobs']!
                    as List<Object?>)
                .single!
            as Map;
    for (final payload in [
      pending['payload']! as String,
      (await client.get('/horizon/api/jobs/failed/d1')).jsonMap['payload']!
          as String,
      (await client.get('/horizon/api/jobs/failed/l1')).jsonMap['payload']!
          as String,
    ]) {
      expect(payload, isNot(contains('hidden-value')));
      expect(payload, isNot(contains('tenant_key')));
      expect(payload, isNot(contains('hunter2')));
      expect(payload, contains('t-visible'), reason: 'visible context stays');
      expect(jsonDecode(payload), isA<Map<String, Object?>>());
    }
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
    final all = (await client.post('/horizon/api/jobs/retry-all')).jsonMap;
    expect(all['retried'], 1);
    expect(all['remaining'], 0);
    expect(all['skipped_count'], 0);
    expect(await app.run(() => Queue.size('a')), 2);
  });

  test('retry-all: at most 1000 a request, continued with after and up_to; '
      'an unreadable payload stays, reported', () async {
    await boot();
    await app.run(() async {
      final failed = App.make<QueueManager>().processor.failedJobs;
      for (var i = 0; i < 1500; i++) {
        await failed.log(
          connection: 'database',
          queue: 'a',
          payload: i == 700
              ? '{"job":"mail","uuid":5}'
              : JobPayload.forJob(const Mail(), uuid: 'r$i').encode(),
          exception: 'StateError: boom',
        );
      }
    });
    final first = (await client.post('/horizon/api/jobs/retry-all')).jsonMap;
    expect(first['retried'], 999, reason: '1000 handled, one unreadable');
    expect(first['skipped_count'], 1);
    expect((first['skipped']! as List).single, containsPair('id', 701));
    expect(first['remaining'], 500);
    final second = (await client.post(
      '/horizon/api/jobs/retry-all'
      '?after=${first['after']}&up_to=${first['up_to']}',
    )).jsonMap;
    expect(second['retried'], 500);
    expect(second['remaining'], 0);
    expect(await app.run(() => Queue.size('a')), 1499);
    final left = await app.run(
      () => App.make<QueueManager>().processor.failedJobs.all(),
    );
    expect([for (final job in left) job.id], [701]);
  });

  test('retry-all while another runs: 409', () async {
    await boot();
    final lock = app.container.make<QueueManager>().signalStore!.lock(
      'queue:retry-all',
      owner: 'someone-else',
    );
    expect(await lock.acquire(), isTrue);
    final response = await client.post('/horizon/api/jobs/retry-all');
    expect(response.status, 409);
    expect(response.jsonMap['message'], contains('already being retried'));
    await lock.release();
    expect((await client.post('/horizon/api/jobs/retry-all')).status, 200);
  });

  test('stream: server-sent events that end when the server drains', () async {
    await boot();
    app.drainSignal.signal();
    final response = await client.get('/horizon/api/stream');
    expect(response.status, 200);
    expect(response.headers['content-type'], 'text/event-stream');
    expect(response.body, contains('retry: '));
  });

  test('outside local, every endpoint needs the gate', () async {
    await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:${base64.encode(List.filled(32, 7))}',
    });
    HorizonDashboard.auth(null);
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

  test('HORIZON_PATH=/ serves the dashboard at the root, without double '
      'slashes', () async {
    await boot({'HORIZON_PATH': '/'});
    final paths = [
      for (final route in app.router.routes)
        if (route.routeName?.startsWith('horizon.') ?? false) route.path,
    ];
    expect(paths, contains('/api/stats'));
    expect(paths.where((p) => p.contains('//')), isEmpty);
    (await client.get('/api/stats')).assertOk();
    final page = await client.get('/');
    page.assertOk();
    expect(page.body, contains('data-base=""'));
    expect(page.body, contains('href="/failed"'));
    expect(page.body, isNot(contains('"//')));
    (await client.get('/failed')).assertOk();
  });

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

  test('the page needs the gate outside local too', () async {
    await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:${base64.encode(List.filled(32, 7))}',
    });
    HorizonDashboard.auth(null);
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

  test('a status whose workers are not maps: stats and workload answer, '
      'those workers on no queue', () async {
    await boot();
    final signals = app.container.make<QueueManager>().signalStore!;
    await app.run(
      () => signals.store.forever(
        HorizonSignals.statusKey('horizon'),
        jsonEncode({
          'state': 'running',
          'at': DateTime.now().millisecondsSinceEpoch,
          'supervisors': {
            's': ['x', 7, null],
          },
        }),
      ),
    );
    expect((await client.get('/horizon/api/stats')).status, 200);
    final workload = await client.get('/horizon/api/workload');
    expect(workload.status, 200);
    expect(((workload.json! as List).single! as Map)['processes'], 0);
  });

  test('a huge starting_at is held at maxOffset: a bounded number of '
      'queries per queue', () async {
    await boot({'TEST_QUEUES': 'a,b,c,d'});
    await app.run(() => Queue.push(const Mail(), queue: 'a'));
    var queries = 0;
    final stop = app.container.make<DatabaseManager>().listen((_) => queries++);
    addTearDown(stop);
    final response = await client.get(
      '/horizon/api/jobs/pending?starting_at=9223372036854775807',
    );
    expect(response.status, 200);
    expect(response.jsonMap['jobs'], isEmpty);
    // Per queue: one page read, then the bisection of at most
    // log2(100 000) ≈ 17 one-job reads.
    expect(queries, lessThanOrEqualTo(4 * (1 + 17)));
    expect(HorizonDashboard.maxOffset, 100000);
  });

  test('HORIZON_PATH=/ outside local: a tab is behind the gate (403); any '
      "other path is not the dashboard's (the application's own 200, an "
      'unknown 404)', () async {
    HorizonDashboard.auth(null);
    await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      'HORIZON_PATH': '/',
    });
    expect((await client.get('/dashboard')).status, 403);
    expect((await client.get('/failed')).status, 403);
    expect((await client.get('/about')).status, 200);
    expect((await client.get('/apa-saja')).status, 404);
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
