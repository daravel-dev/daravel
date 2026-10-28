import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `HTTP_MAX_IN_FLIGHT`: a worker refuses the request above its limit with
/// `503` before routing, keeps answering the health probes, and frees the
/// slot once the response (and terminate phase) is done.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;
  late Completer<void> gate;
  late HttpClient client;

  Future<HttpClientResponse> get(String path) async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${engine.port}$path'),
    );
    return request.close();
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met within 5s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    gate = Completer<void>();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/block', (request) async {
              await gate.future;
              return 'released';
            });
            router.get('/fast', (request) => 'ok');
            // Synchronous work: the request never yields, so it is never
            // "in flight" for a second request, yet it stalls the loop.
            router.get('/spin', (request) {
              final until = DateTime.now().add(
                const Duration(milliseconds: 40),
              );
              while (DateTime.now().isBefore(until)) {}
              return 'spun';
            });
            router.ws('/socket', (socket, request) async {
              await socket.first;
              await socket.close();
            });
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    log = MemoryHandler();
    engine = ServerEngine(
      app,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        maxInFlight: 2,
      ),
      kernel: app.kernel,
      logger: Logger(handlers: [log]),
      onShed: app.container.make<AppMetrics>().recordShed,
    );
    await engine.start();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
      return engine.stop();
    });
    client = HttpClient();
    addTearDown(() => client.close(force: true));
  });

  test(
    'refuses the request above the limit with 503 and Retry-After',
    () async {
      final held = [get('/block'), get('/block')];
      await waitFor(() => engine.inFlight == 2);

      final refused = await get('/fast');
      expect(refused.statusCode, 503);
      expect(refused.headers.value(HttpHeaders.retryAfterHeader), '1');
      expect(refused.headers.contentType?.mimeType, 'application/json');
      expect(refused.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
      final body = jsonDecode(await utf8.decodeStream(refused));
      expect(body, {'message': 'Service Unavailable'});
      expect(engine.shedRequests, 1);
      expect(engine.inFlight, 2, reason: 'a refused request takes no slot');

      gate.complete();
      for (final response in await Future.wait(held)) {
        expect(response.statusCode, 200);
        await response.drain<void>();
      }
      await waitFor(() => engine.inFlight == 0);

      final again = await get('/fast');
      expect(again.statusCode, 200);
      await again.drain<void>();
      expect(engine.shedRequests, 1);
    },
  );

  test('never refuses the health probes', () async {
    final held = [get('/block'), get('/block')];
    await waitFor(() => engine.inFlight == 2);

    final live = await get('/up');
    expect(live.statusCode, 200);
    await live.drain<void>();
    final ready = await get('/up/ready');
    expect(ready.statusCode, 200);
    await ready.drain<void>();
    expect(engine.shedRequests, 0);

    gate.complete();
    for (final response in await Future.wait(held)) {
      await response.drain<void>();
    }
  });

  test(
    'logs the refusal at most once a second and counts the metric',
    () async {
      final held = [get('/block'), get('/block')];
      await waitFor(() => engine.inFlight == 2);

      for (var i = 0; i < 5; i++) {
        await (await get('/fast')).drain<void>();
      }
      expect(engine.shedRequests, 5);
      final warnings = log.records.where(
        (r) =>
            r.level == LogLevel.warning && r.message.contains('Load shedding'),
      );
      expect(warnings.length, 1);
      expect(warnings.first.message, contains('2 requests in flight'));
      expect(warnings.first.message, contains('GET /fast'));
      final metrics = app.container.make<AppMetrics>().registry.render();
      expect(
        metrics,
        matches(RegExp(r'http_requests_shed_total{worker="[^"]+"} 5')),
      );

      gate.complete();
      for (final response in await Future.wait(held)) {
        await response.drain<void>();
      }
    },
  );

  test('an open WebSocket holds a socket, not a slot', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${engine.port}/socket',
    );
    addTearDown(() => socket.close());
    await waitFor(() => engine.openWebSockets == 1);
    expect(engine.inFlight, 0);

    final held = [get('/block'), get('/block')];
    await waitFor(() => engine.inFlight == 2);
    expect((await get('/fast')).statusCode, 503);

    gate.complete();
    for (final response in await Future.wait(held)) {
      await response.drain<void>();
    }
    socket.add('bye');
    // Listening consumes the server's close frame; `done` alone would wait.
    await socket.drain<void>();
    await waitFor(() => engine.openWebSockets == 0);
  });

  test('a worker without a limit never sheds', () async {
    await engine.stop();
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [log]),
    );
    await engine.start();

    final held = [get('/block'), get('/block'), get('/block')];
    await waitFor(() => engine.inFlight == 3);
    final response = await get('/fast');
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(engine.shedRequests, 0);

    gate.complete();
    for (final response in await Future.wait(held)) {
      await response.drain<void>();
    }
  });

  group('HTTP_MAX_QUEUE_DELAY', () {
    late ServerEngine lagged;

    setUp(() async {
      lagged = ServerEngine(
        app,
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          maxQueueDelay: Duration(milliseconds: 30),
        ),
        kernel: app.kernel,
        logger: Logger(handlers: [log]),
      );
      await lagged.start();
      addTearDown(lagged.stop);
    });

    Future<HttpClientResponse> getLagged(String path) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${lagged.port}$path'),
      );
      return request.close();
    }

    test('synchronous work never counts as in flight', () async {
      expect(lagged.inFlight, 0);
      final response = await getLagged('/spin');
      expect(response.statusCode, 200);
      await response.drain<void>();
      // The slot is held until terminate() has run, which can be after the
      // client has read the response.
      await waitFor(() => lagged.inFlight == 0);
    });

    test('sheds when the event loop falls behind, recovers after', () async {
      // 12 × 40 ms of synchronous work queued at once: the loop is ~400 ms
      // behind by the end, far above the 30 ms limit.
      final flood = [for (var i = 0; i < 12; i++) getLagged('/spin')];
      final statuses = <int>[];
      for (final response in await Future.wait(flood)) {
        statuses.add(response.statusCode);
        await response.drain<void>();
      }
      expect(statuses, contains(503));
      expect(statuses, contains(200), reason: 'the first requests are served');
      expect(lagged.shedRequests, greaterThan(0));
      expect(lagged.shedRequests, lessThan(12));
      final warning = log.records.firstWhere(
        (r) => r.message.contains('Load shedding'),
      );
      expect(warning.message, contains('event loop'));
      expect(warning.message, contains('ms behind'));

      await waitFor(() => lagged.queueDelay < const Duration(milliseconds: 30));
      final after = await getLagged('/fast');
      expect(after.statusCode, 200);
      await after.drain<void>();
    });

    test('an idle loop reports no delay', () async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Windows' default timer resolution is 15.6 ms, so a 5 ms tick reads
      // up to 10 ms late when no other process has raised it: the idle
      // reading is bounded by that granularity, not zero.
      expect(lagged.queueDelay, lessThan(const Duration(milliseconds: 20)));
    });
  });

  group('ServeOptions.fromEnv', () {
    ServeOptions from(Map<String, String> values) =>
        ServeOptions.fromEnv(Env.fromMap(values));

    test('reads HTTP_MAX_IN_FLIGHT, 0 or unset meaning no limit', () {
      expect(from(const {}).maxInFlight, isNull);
      expect(from(const {'HTTP_MAX_IN_FLIGHT': '0'}).maxInFlight, isNull);
      expect(from(const {'HTTP_MAX_IN_FLIGHT': '256'}).maxInFlight, 256);
      expect(from(const {'HTTP_MAX_IN_FLIGHT': '10'}).maxInFlight, 10);
    });

    test('refuses a negative HTTP_MAX_IN_FLIGHT', () {
      expect(
        () => from(const {'HTTP_MAX_IN_FLIGHT': '-1'}),
        throwsArgumentError,
      );
    });

    test('an explicit argument wins over the environment', () {
      final options = ServeOptions.fromEnv(
        Env.fromMap(const {'HTTP_MAX_IN_FLIGHT': '256'}),
        maxInFlight: 8,
      );
      expect(options.maxInFlight, 8);
    });

    test('reads HTTP_MAX_QUEUE_DELAY as a duration, 0 meaning off', () {
      expect(from(const {}).maxQueueDelay, isNull);
      expect(from(const {'HTTP_MAX_QUEUE_DELAY': '0s'}).maxQueueDelay, isNull);
      expect(
        from(const {'HTTP_MAX_QUEUE_DELAY': '250ms'}).maxQueueDelay,
        const Duration(milliseconds: 250),
      );
      expect(
        ServeOptions.fromEnv(
          Env.fromMap(const {'HTTP_MAX_QUEUE_DELAY': '250ms'}),
          maxQueueDelay: Duration.zero,
        ).maxQueueDelay,
        isNull,
        reason: 'zero on the command line turns the .env limit off',
      );
    });
  });
}
