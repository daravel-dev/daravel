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

Application dashboardApp([Map<String, String> env = const {}]) =>
    Application.configure(basePath: Directory.systemTemp.path)
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

  Future<void> boot([Map<String, String> env = const {}]) async {
    app = dashboardApp(env);
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  }

  tearDown(() => app.shutdown());

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
    expect(response.status, 200);
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
}
