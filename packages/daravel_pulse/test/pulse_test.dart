import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_pulse/daravel_pulse.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    Clock.restore();
    Container.setRoot(null);
  });

  group('recorder', () {
    test('requests by minute; slow ones grouped by route', () {
      Clock.fake(DateTime.utc(2026, 10, 29, 8));
      final recorder = PulseRecorder(worker: 'w0');
      void request(String route, int status, int ms) => recorder.recordRequest(
        method: 'GET',
        route: route,
        status: status,
        duration: Duration(milliseconds: ms),
        slow: ms >= 1000,
      );
      request('/users/{id}', 200, 1500);
      request('/users/{id}', 200, 2500);
      request('/', 200, 20);
      Clock.travel(const Duration(minutes: 2));
      request('/', 500, 30);

      final snapshot = PulseSnapshot.build(
        [recorder.report()],
        window: const Duration(hours: 1),
        now: Clock.now(),
      );
      final totals = snapshot['requests']! as Map<String, Object?>;
      expect(totals['total'], 4);
      expect(totals['errors'], 1);
      expect(totals['slow'], 2);
      expect(totals['avg_ms'], (1500 + 2500 + 20 + 30) / 4);
      final series = (totals['series']! as List<Object?>).cast<List<int>>();
      expect(series, hasLength(60));
      expect(series.fold<int>(0, (sum, p) => sum + p[1]), 4);
      expect(series.last[1], 1, reason: 'the latest minute is the last point');

      final slow = snapshot['slow_requests']! as List<Object?>;
      expect(slow, hasLength(1));
      expect(slow.single, containsPair('route', '/users/{id}'));
      expect(slow.single, containsPair('count', 2));
      expect(slow.single, containsPair('max_ms', 2500.0));
      expect(slow.single, containsPair('avg_ms', 2000.0));
    });

    test('a window leaves older data out; a day later it is gone', () {
      Clock.fake(DateTime.utc(2026, 10, 29, 8));
      final recorder = PulseRecorder(worker: 'w0')
        ..recordQuery('select *\n  from users', 'pgsql', Duration(seconds: 2));
      Clock.travel(const Duration(hours: 2));
      recorder.recordQuery('select 1', 'pgsql', Duration(seconds: 3));

      List<Object?> queries(Duration window) =>
          PulseSnapshot.build(
                [recorder.report()],
                window: window,
                now: Clock.now(),
              )['slow_queries']!
              as List<Object?>;
      expect(queries(const Duration(hours: 1)), hasLength(1));
      final day = queries(const Duration(hours: 24));
      expect(day, hasLength(2));
      expect(
        [for (final q in day) (q! as Map)['sql']],
        containsAll(['select * from users', 'select 1']),
        reason: 'whitespace collapsed, bindings never kept',
      );

      Clock.travel(const Duration(hours: 23));
      recorder.recordQuery('select 2', 'pgsql', Duration(seconds: 1));
      expect(queries(const Duration(hours: 24)), hasLength(2));
      final report = recorder.report();
      expect(
        (report['buckets']! as List<Object?>).length,
        lessThanOrEqualTo(2),
        reason: 'buckets older than a day are dropped',
      );
    });

    test('exceptions by class and place, with the latest message', () {
      Clock.fake(DateTime.utc(2026, 10, 29, 8));
      final recorder = PulseRecorder(worker: 'w0');
      for (var i = 0; i < 3; i++) {
        try {
          throw StateError('order $i failed');
        } on StateError catch (error, stack) {
          recorder.recordException(error, stack);
        }
        Clock.travel(const Duration(seconds: 1));
      }
      final exceptions =
          PulseSnapshot.build(
                [recorder.report()],
                window: const Duration(hours: 1),
                now: Clock.now(),
              )['exceptions']!
              as List<Object?>;
      expect(exceptions, hasLength(1));
      final group = exceptions.single! as Map<String, Object?>;
      expect(group['class'], 'StateError');
      expect(group['count'], 3);
      expect(group['message'], 'Bad state: order 2 failed');
      expect(group['location'], contains('pulse_test.dart'));
      expect(group['trace'], contains('pulse_test.dart'));
    });

    test('isolates merge; groups per bucket are bounded', () {
      Clock.fake(DateTime.utc(2026, 10, 29, 8));
      final one = PulseRecorder(worker: 'daravel-worker-0', maxGroups: 3);
      final two = PulseRecorder(worker: 'daravel-worker-1', maxGroups: 3);
      for (final recorder in [one, two]) {
        recorder
          ..recordJob('SendInvoice', 'default', Duration(seconds: 2))
          ..recordJob('SendInvoice', 'default', Duration.zero, failed: true);
      }
      for (var i = 0; i < 10; i++) {
        one.recordQuery('select $i', 'sqlite', Duration(seconds: 1));
      }
      final snapshot = PulseSnapshot.build(
        [one.report(), two.report()],
        window: const Duration(hours: 1),
        now: Clock.now(),
      );
      final jobs = snapshot['jobs']! as List<Object?>;
      expect(jobs.single, containsPair('count', 4));
      expect(jobs.single, containsPair('failed', 2));
      expect(jobs.single, containsPair('max_ms', 2000.0));
      expect(snapshot['slow_queries'], hasLength(3));
      expect(
        [
          for (final w in snapshot['workers']! as List<Object?>)
            (w! as Map)['name'],
        ],
        ['daravel-worker-0', 'daravel-worker-1'],
      );
    });
  });

  group('HTTP', () {
    late Directory dir;
    late Application app;

    setUp(() => dir = Directory.systemTemp.createTempSync('daravel_pulse_'));
    tearDown(() async {
      await app.shutdown();
      dir.deleteSync(recursive: true);
    });

    Future<Application> boot({
      Map<String, String> env = const {},
      List<Object> middleware = const [],
    }) async {
      final application = Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'LOG_LEVEL': 'emergency',
            'PULSE_SLOW_REQUESTS_THRESHOLD': '0',
            'PULSE_SLOW_QUERIES_THRESHOLD': '0',
            ...env,
          })
          .withPulse(middleware: middleware)
          .withMiddleware((m) => m.alias('allow', _Allow()))
          .withRouting(
            api: (router) {
              router
                ..get('/users/{id}', (Request request) async {
                  await DB.select('select 1 as one');
                  return {'id': request.param<int>('id')};
                })
                ..get('/boom', (_) => throw StateError('Something broke'))
                ..get('/gone', (_) => throw NotFoundHttpException());
            },
          )
          .create();
      await application.boot();
      return application;
    }

    Future<(int, Response)> get(String path) async {
      final response = await app.handle(Request.fake(path: path));
      return (response.status, response);
    }

    Future<Map<String, Object?>> stats([String period = '1h']) async {
      final (status, response) = await get('/pulse/api/stats?period=$period');
      expect(status, 200);
      return jsonDecode(await response.bodyText()) as Map<String, Object?>;
    }

    test('requests, queries and server errors reach the dashboard', () async {
      app = await boot();
      expect((await get('/api/users/7')).$1, 200);
      expect((await get('/api/users/8')).$1, 200);
      expect((await get('/api/boom')).$1, 500);
      expect((await get('/api/gone')).$1, 404);

      final data = await stats();
      final requests = data['requests']! as Map<String, Object?>;
      expect(requests['total'], 4, reason: 'the dashboard itself not counted');
      expect(requests['errors'], 1);
      final routes = [
        for (final r in data['slow_requests']! as List<Object?>)
          (r! as Map)['route'],
      ];
      expect(routes, contains('/api/users/{id}'));
      expect(
        (data['slow_requests']! as List<Object?>).firstWhere(
          (r) => (r! as Map)['route'] == '/api/users/{id}',
        ),
        containsPair('count', 2),
      );
      final queries = data['slow_queries']! as List<Object?>;
      expect(
        queries.any((q) => (q! as Map)['sql'] == 'select 1 as one'),
        isTrue,
      );
      final exceptions = data['exceptions']! as List<Object?>;
      expect(exceptions, hasLength(1), reason: 'a 404 is not a server error');
      expect(exceptions.single, containsPair('class', 'StateError'));
      expect(
        exceptions.single,
        containsPair('message', 'Bad state: Something broke'),
      );
      expect(data['queues'], [
        {'connection': 'sync', 'queue': 'default', 'size': 0},
      ]);
      expect(data['failed_jobs'], containsPair('count', 0));
      expect(data['workers'], hasLength(1));
      expect(data['memory_bytes'], greaterThan(0));
      expect(data['thresholds'], containsPair('requests_ms', 0));
    });

    test('jobs that fail are listed with their queue', () async {
      app = await boot();
      await app.run(
        () => Container.current.make<EventDispatcher>().dispatch(
          const JobFailed(
            connection: 'database',
            queue: 'mail',
            jobName: 'SendInvoice',
            jobId: 1,
            error: 'boom',
          ),
        ),
      );
      final jobs = (await stats())['jobs']! as List<Object?>;
      expect(jobs.single, containsPair('job', 'SendInvoice'));
      expect(jobs.single, containsPair('queue', 'mail'));
      expect(jobs.single, containsPair('failed', 1));
    });

    test('the page: a nonce CSP and no external assets', () async {
      app = await boot();
      final (status, response) = await get('/pulse');
      expect(status, 200);
      final csp = response.headers.first('content-security-policy')!;
      final nonce = RegExp("'nonce-([^']+)'").firstMatch(csp)![1];
      final html = await response.bodyText();
      expect(html, contains('<script nonce="$nonce">'));
      expect(html, contains('data-base="/pulse"'));
      // No external assets: nothing loaded from elsewhere.
      expect(html, isNot(contains(RegExp(r'(src|href)="https?:'))));
      expect(html, isNot(contains('<link')));
      expect(response.headers.first('x-frame-options'), 'DENY');
    });

    test('closed outside local without middleware; 404 when off', () async {
      final production = {
        'APP_ENV': 'production',
        'APP_KEY': 'base64:${base64Encode(List.filled(32, 7))}',
      };
      app = await boot(env: production);
      expect((await get('/pulse')).$1, 403);
      expect((await get('/pulse/api/stats')).$1, 403);
      await app.shutdown();

      app = await boot(env: production, middleware: ['allow']);
      expect((await get('/pulse')).$1, 200);
      await app.shutdown();

      app = await boot(env: {'PULSE_ENABLED': 'false'});
      expect((await get('/pulse')).$1, 404);
      expect((await get('/api/users/1')).$1, 200);
      expect(app.container.make<PulseRecorder>().requestsTotal, 0);
    });

    test('under a supervisor it shows every worker\'s report', () async {
      final coordinator = createStandardCoordinator();
      addTearDown(coordinator.close);
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      app =
          Application.configure(basePath: dir.path)
              .withEnv({
                'APP_ENV': 'testing',
                'DB_DATABASE': ':memory:',
                'LOG_LEVEL': 'emergency',
              })
              .withPulse()
              .withRouting(api: (router) => router.get('/ping', (_) => 'pong'))
              .create()
            ..coordinator = channel;
      await app.boot();
      // Another worker isolate's report, as its publisher sends it.
      final other = PulseRecorder(worker: 'daravel-worker-1')
        ..recordRequest(
          method: 'GET',
          route: '/api/ping',
          status: 200,
          duration: const Duration(milliseconds: 5),
          slow: false,
        );
      await WorkerReports(
        channel,
        worker: 'daravel-worker-1',
      ).publish(Pulse.topic, other.report());
      expect((await get('/api/ping')).$1, 200);

      final data = await stats();
      expect((data['requests']! as Map)['total'], 2);
      expect(data['workers'], hasLength(2));
    });
  });
}

final class _Allow implements Middleware {
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}
