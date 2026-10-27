import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Logger', () {
    test('levels, redaction, shared and scope context', () async {
      final memory = MemoryHandler();
      final logger = Logger(minimumLevel: .info, handlers: [memory])
        ..shareContext({'app': 'demo'});
      logger
        ..debug('hidden')
        ..info('login', {
          'email': 'a@b.c',
          'password': 'hunter2',
          'headers': {'Authorization': 'Bearer x', 'accept': 'json'},
          'list': [
            {'api_key': 'k'},
          ],
        })
        ..critical('boom', error: StateError('x'));
      expect(memory.records, hasLength(2));
      final ctx = memory.records.first.context;
      expect(ctx['app'], 'demo');
      expect(ctx['password'], '[REDACTED]');
      expect((ctx['headers']! as Map)['Authorization'], '[REDACTED]');
      expect((ctx['headers']! as Map)['accept'], 'json');
      expect(((ctx['list']! as List).first as Map)['api_key'], '[REDACTED]');
      memory
        ..assertLogged(LogLevel.critical, 'boom')
        ..assertNotLogged(LogLevel.debug);
      expect(() => memory.assertLogged(LogLevel.error), throwsStateError);
      expect(LogLevel.parse('WARN'), LogLevel.warning);
      expect(() => LogLevel.parse('loud'), throwsA(isA<ConfigException>()));
    });

    test('JSON and daily file handlers', () async {
      final buffer = StringBuffer();
      Logger(
        handlers: [JsonHandler(buffer)],
        channel: 'json',
      ).warning('w', {'k': 1});
      final line = jsonDecode(buffer.toString().trim()) as Map<String, Object?>;
      expect(line['level'], 'warning');
      expect(line['channel'], 'json');
      expect(line['context'], {'k': 1});

      final dir = await Directory.systemTemp.createTemp('daravel_logs_');
      addTearDown(() => dir.delete(recursive: true));
      for (final old in [
        'daravel-2020-01-01.log',
        'daravel-2020-01-02.log',
        'other.log',
      ]) {
        File(p.join(dir.path, old)).writeAsStringSync('x');
      }
      final daily = DailyFileHandler(dir.path, days: 2);
      final logger = Logger(handlers: [daily])..info('to file');
      await logger.close();
      final today = File(daily.pathFor(DateTime.now()));
      expect(today.readAsStringSync(), contains('"message":"to file"'));
      final remaining = dir.listSync().map((f) => p.basename(f.path)).toSet();
      expect(remaining, contains('other.log'));
      expect(remaining, contains('daravel-2020-01-02.log'));
      expect(remaining, isNot(contains('daravel-2020-01-01.log')));
    });

    test('daily pruning keeps today plus days - 1, whether or not today '
        'already exists', () async {
      for (final todayExists in [false, true]) {
        final dir = await Directory.systemTemp.createTemp('daravel_logs_');
        addTearDown(() => dir.delete(recursive: true));
        final daily = DailyFileHandler(dir.path, days: 2);
        final today = p.basename(daily.pathFor(DateTime.now()));
        for (final old in [
          'daravel-2020-01-01.log',
          'daravel-2020-01-02.log',
          'daravel-2020-01-03.log',
          if (todayExists) today,
        ]) {
          File(p.join(dir.path, old)).writeAsStringSync('x\n');
        }
        final logger = Logger(handlers: [daily])..info('to file');
        await logger.close();
        final remaining = dir.listSync().map((f) => p.basename(f.path)).toSet();
        expect(remaining, {
          today,
          'daravel-2020-01-03.log',
        }, reason: 'today exists: $todayExists');
      }
    });

    test('fromConfig builds stacks and named channels', () {
      final logger = Logger.fromConfig(
        const LoggingConfig(stack: ['console', 'json']),
        basePath: Directory.systemTemp.path,
      );
      expect(logger.handlers.map((h) => h.runtimeType), [
        ConsoleHandler,
        JsonHandler,
      ]);
      expect(logger.channelNamed('null').handlers, isEmpty);
      expect(logger.channelNamed('stack'), same(logger));
      expect(
        () => logger.channelNamed('slack'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => Logger.fromConfig(
          const LoggingConfig(channel: 'carrier-pigeon'),
          basePath: '.',
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('Metrics', () {
    test('registry renders Prometheus text and merges snapshots', () {
      final a = MetricsRegistry();
      a.counter('jobs_total', 'Jobs.').inc({'status': 'ok'}, 2);
      a.gauge('temp', 'Temperature.').set(1.5);
      a.histogram('lat', 'Latency.', buckets: [0.1, 1]).observe(0.05);
      final b = MetricsRegistry();
      b.counter('jobs_total', 'Jobs.').inc({'status': 'ok'});
      b.counter('jobs_total', 'Jobs.').inc({'status': 'failed'});
      b.histogram('lat', 'Latency.', buckets: [0.1, 1]).observe(0.5);

      final text = MetricsRegistry.renderSnapshot(
        MetricsRegistry.merge([a.snapshot(), b.snapshot()]),
      );
      expect(text, contains('# TYPE jobs_total counter'));
      expect(text, contains('jobs_total{status="ok"} 3'));
      expect(text, contains('jobs_total{status="failed"} 1'));
      expect(text, contains('temp 1.5'));
      expect(text, contains('lat_bucket{le="0.1"} 1'));
      expect(text, contains('lat_bucket{le="1"} 2'));
      expect(text, contains('lat_bucket{le="+Inf"} 2'));
      expect(text, contains('lat_count 2'));
      expect(a.render(), contains('jobs_total{status="ok"} 2'));
    });
  });

  group('HTTP endpoints', () {
    late Application app;

    Future<void> boot(
      Map<String, String> env, {
      List<HealthCheck> checks = const [],
    }) async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
          .withLogLevel(LogLevel.warning)
          .withHealthChecks(checks)
          .withRouting(
            apiPrefix: '',
            api: (router) {
              router.get('/users/{id}', (req) {
                Log.withContext({'user': req.param<String>('id')});
                Log.warning('viewing user');
                return {'id': req.param<String>('id')};
              });
            },
          )
          .create();
      await app.boot();
    }

    tearDown(() => app.shutdown());

    test('/metrics exposes route-labelled HTTP metrics behind a token', () async {
      await boot({'METRICS_ENABLED': 'true', 'METRICS_TOKEN': 's3cret'});
      await app.handle(Request.fake(path: '/users/1'));
      await app.handle(Request.fake(path: '/users/2'));
      await app.handle(Request.fake(path: '/nope'));
      expect((await app.handle(Request.fake(path: '/metrics'))).status, 401);
      final response = await app.handle(
        Request.fake(
          path: '/metrics',
          headers: {'authorization': 'Bearer s3cret'},
        ),
      );
      expect(response.status, 200);
      expect(
        response.headers['content-type'],
        startsWith('text/plain; version=0.0.4'),
      );
      final text = await response.bodyText();
      expect(
        text,
        contains(
          'http_requests_total{method="GET",route="/users/{id}",status="200"} 2',
        ),
      );
      expect(
        text,
        contains(
          'http_requests_total{method="GET",route="unmatched",status="404"} 1',
        ),
      );
      expect(
        text,
        contains(
          'http_request_duration_seconds_count{method="GET",route="/users/{id}"} 2',
        ),
      );
      expect(text, contains('process_resident_memory_bytes'));
      // One series per worker isolate, so uneven workers show.
      expect(
        text,
        contains(
          'http_requests_in_flight{worker="${Isolate.current.debugName}"}',
        ),
      );
      // The coordinator's own counters, in one isolate too.
      expect(text, contains('# TYPE coordinator_messages_total counter'));
      expect(text, matches(RegExp(r'\ncoordinator_messages_total \d+\n')));
      expect(text, contains('coordinator_in_flight 0'));
    });

    test('/metrics is absent unless enabled', () async {
      await boot({});
      expect((await app.handle(Request.fake(path: '/metrics'))).status, 404);
    });

    test('/up/ready reports each check and fails with 503', () async {
      await boot(
        {},
        checks: [
          CallbackHealthCheck(
            'queue',
            () => const HealthResult.ok({'size': 0}),
          ),
        ],
      );
      final ok = await app.handle(Request.fake(path: '/up/ready'));
      expect(ok.status, 200);
      final body = jsonDecode(await ok.bodyText()) as Map<String, Object?>;
      expect(body['status'], 'ok');
      final checks = body['checks']! as Map<String, Object?>;
      expect(checks.keys, ['database', 'cache', 'queue']);
      expect((checks['queue']! as Map)['size'], 0);
      await app.shutdown();

      await boot(
        {},
        checks: [
          CallbackHealthCheck('broken', () => throw StateError('down')),
          CallbackHealthCheck('slow', () async {
            await Future<void>.delayed(const Duration(seconds: 3));
            return const HealthResult.ok();
          }),
        ],
      );
      final failing = await app.handle(Request.fake(path: '/up/ready'));
      expect(failing.status, 503);
      final failed =
          (jsonDecode(await failing.bodyText()) as Map)['checks'] as Map;
      expect((failed['broken'] as Map)['error'], contains('down'));
      expect((failed['slow'] as Map)['error'], contains('Timed out'));
      expect((failed['database'] as Map)['ok'], isTrue);
    });

    test('request logs carry request_id and Log.withContext data', () async {
      await boot({});
      final spy = await app.run(() async => Log.spy());
      await app.handle(Request.fake(path: '/users/7', id: 'req-123'));
      final record = spy.matching(LogLevel.warning, 'viewing user').single;
      expect(record.context['request_id'], 'req-123');
      expect(record.context['user'], '7');
    });
  });
}
