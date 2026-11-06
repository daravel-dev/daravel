import 'dart:async';
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

    test('snapshots merge and render the same after a JSON round trip', () {
      // ADR-031: workers publish snapshots as JSON text. Integral doubles
      // (3.0, 1e15), fractions, negatives, label escapes, the default
      // buckets and int bucket counts must all come back as they left.
      MetricsRegistry registry(double by) {
        final r = MetricsRegistry();
        r.counter('jobs_total', 'Jobs.')
          ..inc({'status': 'ok'}, 3 * by)
          ..inc({'queue': 'a"b\\c'}, 1e15 * by);
        r.gauge('temp', 'Temperature.')
          ..set(-1.25 * by)
          ..set(1e21, {'big': 'yes'});
        r.gauge('rss', 'Collected.', collect: () => 4096.0 * by);
        r.histogram('lat', 'Latency.')
          ..observe(0.003 * by, {'route': '/users/{id}'})
          ..observe(2.5 * by, {'route': '/users/{id}'})
          ..observe(42 * by);
        r.histogram('small', 'Custom buckets.', buckets: [0.1, 1, 10])
          ..observe(0.1 * by)
          ..observe(11);
        return r;
      }

      final snapshots = [registry(1).snapshot(), registry(0.5).snapshot()];
      final wire = [
        for (final s in snapshots)
          jsonDecode(jsonEncode(s)) as Map<String, Object?>,
      ];
      final expected = MetricsRegistry.renderSnapshot(
        MetricsRegistry.merge(snapshots),
      );
      expect(
        MetricsRegistry.renderSnapshot(MetricsRegistry.merge(wire)),
        expected,
      );
      expect(MetricsRegistry.merge(wire), MetricsRegistry.merge(snapshots));
      expect(expected, contains('jobs_total{status="ok"} 4.5'));
      expect(expected, contains('small_bucket{le="10"} 2'));

      // The coordinator service: JSON text and plain maps (a snapshot JSON
      // cannot hold) merge alike.
      final service = MetricsService()
        ..handle('publish', {
          'worker': 'w0',
          'snapshot': jsonEncode(snapshots[0]),
        })
        ..handle('publish', {'worker': 'w1', 'snapshot': snapshots[1]});
      expect(
        MetricsRegistry.renderSnapshot(
          service.handle('collect', const {})! as Map<String, Object?>,
        ),
        expected,
      );
    });

    test('maxSeries caps every metric and counts the overflow (#149)', () {
      final r = MetricsRegistry(maxSeries: 3);
      final counter = r.counter('hits_total', 'Hits.');
      final gauge = r.gauge('level', 'Level.');
      final histogram = r.histogram('lat', 'Latency.', buckets: [1]);
      for (var i = 0; i < 100; i++) {
        counter.inc({'user': '$i'});
        gauge.set(i.toDouble(), {'user': '$i'});
        histogram.observe(0.5, {'user': '$i'});
      }
      // Existing series keep counting; new ones land in the overflow.
      counter.inc({'user': '0'});
      final snapshot = r.snapshot();
      Map<Object?, Object?> series(String name) =>
          (snapshot[name]! as Map)['series'] as Map;
      expect(series('hits_total'), hasLength(4));
      expect(series('level'), hasLength(4));
      expect(series('lat'), hasLength(4));
      expect(counter.value({'user': '0'}), 2);
      expect(series('hits_total')[overflowSeries], 97);
      final text = r.render();
      expect(text, contains('hits_total{overflow="true"} 97'));
      expect(text, contains('lat_count{overflow="true"} 97'));
      expect(
        text,
        contains('metrics_series_dropped_total{metric="hits_total"} 97'),
      );
      expect(text, contains('metrics_series_dropped_total{metric="lat"} 97'));

      // 0: no limit.
      final unlimited = MetricsRegistry(maxSeries: 0);
      for (var i = 0; i < 100; i++) {
        unlimited.counter('c', 'C.').inc({'k': '$i'});
      }
      expect(
        ((unlimited.snapshot()['c']! as Map)['series'] as Map).length,
        100,
      );
    });

    test('the coordinator service forgets exited workers and refuses '
        'oversized snapshots (#149)', () {
      final a = MetricsRegistry();
      a.gauge('in_flight', 'In flight.').set(3, {'worker': 'w0'});
      final service = MetricsService(maxSnapshotBytes: 1000)
        ..handle('publish', {
          'worker': 'w0',
          'snapshot': jsonEncode(a.snapshot()),
        });
      String collect() => MetricsRegistry.renderSnapshot(
        service.handle('collect', const {})! as Map<String, Object?>,
      );
      expect(collect(), contains('in_flight{worker="w0"} 3'));
      final huge = MetricsRegistry(maxSeries: 0);
      for (var i = 0; i < 100; i++) {
        huge.counter('c', 'C.').inc({'k': '$i'});
      }
      expect(
        service.handle('publish', {
          'worker': 'w1',
          'snapshot': jsonEncode(huge.snapshot()),
        }),
        isFalse,
      );
      expect(collect(), isNot(contains('c{')));
      expect(service.stats()['refused'], 1);
      service.forgetWorker('w0');
      expect(collect(), isNot(contains('in_flight')));
      expect(service.stats()['workers'], 0);
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

    test('unknown HTTP methods are counted as other (#149)', () async {
      await boot({'METRICS_ENABLED': 'true'});
      Future<String> scrape() async =>
          (await app.handle(Request.fake(path: '/metrics'))).bodyText();
      await app.handle(Request.fake(method: 'BREW', path: '/users/1'));
      final before = (await scrape()).split('\n').length;
      for (var i = 0; i < 100; i++) {
        await app.handle(Request.fake(method: 'ZZZ$i', path: '/users/1'));
      }
      final text = await scrape();
      expect(
        text,
        contains(
          'http_requests_total{method="other",route="unmatched",status="405"} 101',
        ),
      );
      expect(text, isNot(contains('BREW')));
      expect(text, isNot(contains('ZZZ')));
      // The scrape itself adds its own GET /metrics series.
      expect(text.split('\n').length, lessThanOrEqualTo(before + 16));
    });

    test('/metrics is absent unless enabled', () async {
      await boot({});
      expect((await app.handle(Request.fake(path: '/metrics'))).status, 404);
    });

    test('concurrent /up/ready probes share one run of the checks, and '
        'its result answers the next second (#165)', () async {
      var runs = 0;
      final gate = Completer<void>();
      await boot(
        {},
        checks: [
          CallbackHealthCheck('counted', () async {
            runs++;
            await gate.future;
            return const HealthResult.ok();
          }),
        ],
      );
      final probes = [
        for (var i = 0; i < 10; i++)
          app.handle(Request.fake(path: '/up/ready')),
      ];
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final responses = await Future.wait(probes);
      expect(responses.map((r) => r.status), everyElement(200));
      expect(runs, 1);
      expect((await app.handle(Request.fake(path: '/up/ready'))).status, 200);
      expect(runs, 1, reason: 'within Application.readinessCacheTtl');
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
