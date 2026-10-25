import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final List<String> seen = <String>[];

final class TenantReport extends Job {
  const TenantReport();

  @override
  String get jobName => 'tenant-report';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {
    seen.add(
      'tenant=${Context.get<int>('tenant_id')} '
      'token=${Context.getHidden<String>('api_token')}',
    );
    Log.info('report built');
  }
}

void main() {
  for (final connection in ['memory', 'database']) {
    group('$connection queue', () => _suite(connection));
  }
}

void _suite(String connection) {
  late Application app;
  late Directory base;

  setUp(() async {
    seen.clear();
    base = Directory.systemTemp.createTempSync('daravel_context');
    app = Application.configure(basePath: base.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': connection,
        })
        .withMigrations(const [CreateJobsTable()])
        .withJobs([JobDefinition('tenant-report', (_) => const TenantReport())])
        .withRouting(
          api: (r) => r.post('/reports', (request) async {
            Context.add('tenant_id', 42);
            Context.addHidden('api_token', 'secret-token');
            Context.push('steps', ['validated']);
            Log.info('report requested');
            await Queue.push(const TenantReport());
            return {
              'all': Context.all(),
              'hidden_listed': Context.all().containsKey('api_token'),
            };
          }),
        )
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });
  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('context is logged, kept per request and carried into jobs', () async {
    final logs = await app.run(() async => Log.spy());
    final response = await app.handle(
      Request.fake(method: 'POST', path: '/api/reports'),
    );
    final body = await response.bodyText();
    expect(body, contains('"tenant_id":42'));
    expect(body, contains('"steps":["validated"]'));
    expect(body, contains('"hidden_listed":false'));

    // Visible entries reach the request's log records; hidden ones do not.
    final requested = logs.matching(LogLevel.info, 'report requested').single;
    expect(requested.context['tenant_id'], 42);
    expect(requested.context.containsKey('api_token'), isFalse);

    // A second request starts empty.
    await app.run(() async {
      await Container.current.runScoped<void>('request', (_) async {
        expect(Context.has('tenant_id'), isFalse);
      });
    });

    // The worker restores both visible and hidden entries for the job.
    await app.run(
      () =>
          QueueWorker(Queue.manager)
              .run(const WorkerOptions(stopWhenEmpty: true)),
    );
    expect(seen, ['tenant=42 token=secret-token']);
    final built = logs.matching(LogLevel.info, 'report built').single;
    expect(built.context['tenant_id'], 42);
  });

  test('payloads carry the context only when there is one', () async {
    await app.run(() async {
      await Container.current.runScoped<void>('request', (_) async {
        expect(JobPayload.forJob(const TenantReport()).context, isNull);
        Context.add('tenant_id', 7);
        final payload = JobPayload.forJob(const TenantReport());
        expect(payload.toJson()['context'], {
          'data': {'tenant_id': 7},
          'hidden': <String, Object?>{},
        });
        expect(JobPayload.fromJson(payload.toJson()).context?['data'], {
          'tenant_id': 7,
        });
      });
    });
  });
}
