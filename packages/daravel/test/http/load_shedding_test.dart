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

    /// Waits for the loop to be under the limit, then asks for `/fast` and
    /// expects a 200 with no request shed in between. The lag is read when
    /// the request reaches the engine, a moment after the check, and a slow
    /// runner's timers can run a tick late again in between; an attempt
    /// shed by such a spike is retried. An engine that keeps shedding fails
    /// here.
    Future<void> expectServedOnceCaughtUp() async {
      const limit = Duration(milliseconds: 30);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var status = 0;
      var shedBefore = -1;
      while (status != 200 && DateTime.now().isBefore(deadline)) {
        await waitFor(() => lagged.queueDelay < limit);
        shedBefore = lagged.shedRequests;
        final response = await getLagged('/fast');
        status = response.statusCode;
        await response.drain<void>();
      }
      expect(status, 200, reason: 'requests are served');
      expect(
        lagged.shedRequests,
        shedBefore,
        reason: 'nothing shed after a reading under the limit',
      );
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
      // Start from a loop that has caught up with setUp (boot, two engines
      // binding): on a slow runner its lag alone could shed the first
      // request.
      await waitFor(() => lagged.queueDelay < const Duration(milliseconds: 30));
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

      // Recovery: once the loop has caught up, requests are served again.
      await expectServedOnceCaughtUp();
    });

    test('an idle loop does not shed', () async {
      // queueDelay is how late the 5 ms lag tick ran (a moving average), or
      // how overdue the next tick is at the moment it is read. An idle loop
      // has no work queued, but a busy runner can still run its timer late:
      // macOS coalesces timers, and one reading there was 25 ms. What an
      // idle loop must do is come back under the limit and serve.
      await expectServedOnceCaughtUp();
    });

    test('the lag timer does not run before the first request', () {
      expect(lagged.lagTimerActive, isFalse);
      expect(lagged.queueDelay, Duration.zero);
    });

    test('the lag timer stops once the engine has been idle, and starts again '
        'with the next request', () async {
      final first = await getLagged('/fast');
      expect(first.statusCode, 200);
      await first.drain<void>();
      expect(lagged.lagTimerActive, isTrue);

      // lagIdleStop (1 s) after the last request; waitFor allows 5 s.
      await waitFor(() => !lagged.lagTimerActive);
      expect(lagged.queueDelay, Duration.zero);

      final second = await getLagged('/fast');
      expect(second.statusCode, 200);
      await second.drain<void>();
      expect(lagged.lagTimerActive, isTrue);
      expect(lagged.shedRequests, 0);
    });

    test('an idle gap is not lag: the first request after the timer stopped is '
        'served', () async {
      final warmUp = await getLagged('/fast');
      expect(warmUp.statusCode, 200);
      await warmUp.drain<void>();
      await waitFor(() => !lagged.lagTimerActive);
      final shedBefore = lagged.shedRequests;

      // Block the loop while idle, far above the 30 ms limit.
      final blocked = Stopwatch()..start();
      while (blocked.elapsed < const Duration(milliseconds: 500)) {}

      // The timer is stopped, so the first request is served whatever the
      // loop did meanwhile.
      final first = await getLagged('/fast');
      expect(first.statusCode, 200);
      await first.drain<void>();
      expect(lagged.shedRequests, shedBefore);

      // The second request reads the lag measured since the restart: a
      // timer restarted from where it stopped would see the whole gap (half
      // a second and more) as lag and shed it. A slow runner's timer can
      // run late by itself and shed here too, but by tens of milliseconds.
      final second = await getLagged('/fast');
      await second.drain<void>();
      if (second.statusCode != 200) {
        final warning = log.records.lastWhere(
          (r) => r.message.contains('Load shedding'),
        );
        final behind = RegExp(r'(\d+)ms behind').firstMatch(warning.message);
        expect(behind, isNotNull, reason: warning.message);
        expect(
          int.parse(behind!.group(1)!),
          lessThan(400),
          reason: 'the idle gap was read as lag: ${warning.message}',
        );
      }
    });

    test('the lag timer keeps running for lagIdleStop after the last '
        'request', () async {
      // A runner that stalls between the request and the reading proves
      // nothing either way: such an attempt is repeated.
      for (var attempt = 0; attempt < 5; attempt++) {
        final sinceRequest = Stopwatch()..start();
        final response = await getLagged('/fast');
        expect(response.statusCode, 200);
        await response.drain<void>();
        await waitFor(() => lagged.inFlight == 0);
        // Twenty ticks with nothing in flight.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final active = lagged.lagTimerActive;
        if (sinceRequest.elapsed < const Duration(milliseconds: 600)) {
          expect(active, isTrue, reason: 'stopped before lagIdleStop');
          return;
        }
      }
      fail('no attempt finished within 600 ms of its request');
    });

    test('the lag timer does not stop while the loop is behind', () async {
      // Work that blocks the loop with no request in flight, for longer
      // than lagIdleStop, while the timer still runs: the tick that follows
      // finds the engine idle for long enough to stop, and far behind.
      var blockedWhileActive = false;
      for (var attempt = 0; attempt < 5 && !blockedWhileActive; attempt++) {
        final response = await getLagged('/fast');
        expect(response.statusCode, 200);
        await response.drain<void>();
        await waitFor(() => lagged.inFlight == 0);
        if (!lagged.lagTimerActive) {
          continue;
        }
        blockedWhileActive = true;
        final blocked = Stopwatch()..start();
        while (blocked.elapsed <
            ServerEngine.lagIdleStop + const Duration(milliseconds: 200)) {}
      }
      expect(blockedWhileActive, isTrue);
      // The overdue tick runs before this timer does.
      await Future<void>.delayed(Duration.zero);
      expect(lagged.lagTimerActive, isTrue);
      expect(lagged.queueDelay, greaterThan(const Duration(milliseconds: 30)));

      // Once the loop has caught up, the timer stops.
      await waitFor(() => !lagged.lagTimerActive);
      expect(lagged.queueDelay, Duration.zero);
    });

    test('a request that comes and goes between two ticks counts: the timer '
        'runs for lagIdleStop after it', () async {
      // The second request arrives late in the first one's idle second. A
      // timer that counted from the first would stop a moment after it,
      // unless a tick happened to see the second in flight: so four
      // readings, not one.
      var readings = 0;
      for (var attempt = 0; attempt < 8 && readings < 4; attempt++) {
        if (attempt > 0) {
          // Each reading starts from a stopped timer.
          await waitFor(() => !lagged.lagTimerActive);
        }
        final first = await getLagged('/fast');
        expect(first.statusCode, 200);
        await first.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (!lagged.lagTimerActive) {
          // A stalled runner: the first second is already over.
          continue;
        }
        final sinceSecond = Stopwatch()..start();
        final second = await getLagged('/fast');
        if (second.statusCode == 503) {
          // A stalled runner: the timer is running, the loop was more than
          // maxQueueDelay (30 ms) behind and the engine shed the request.
          // Not a reading; the count below still asks for four.
          await second.drain<void>();
          continue;
        }
        expect(second.statusCode, 200);
        await second.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final active = lagged.lagTimerActive;
        if (sinceSecond.elapsed < const Duration(milliseconds: 900)) {
          expect(active, isTrue, reason: 'counted from the first request');
          readings++;
        }
      }
      expect(readings, 4, reason: 'readings within 900 ms of the request');
    });

    test('the lag timer runs for as long as a request is in flight', () async {
      final pending = getLagged('/block');
      await waitFor(() => lagged.inFlight == 1);
      await Future<void>.delayed(
        ServerEngine.lagIdleStop + const Duration(milliseconds: 300),
      );
      expect(lagged.inFlight, 1);
      expect(lagged.lagTimerActive, isTrue);
      final sinceRelease = Stopwatch()..start();
      gate.complete();
      final response = await pending;
      expect(response.statusCode, 200);
      await response.drain<void>();
      await waitFor(() => lagged.inFlight == 0);
      // The idle second counts from the moment the slot was given back,
      // not from when it was taken (over a second ago).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final active = lagged.lagTimerActive;
      if (sinceRelease.elapsed < const Duration(milliseconds: 800)) {
        expect(active, isTrue, reason: 'counted from when the slot was taken');
      }
      await waitFor(() => !lagged.lagTimerActive);
    });

    test('queueDelay is zero once the engine has stopped', () async {
      final response = await getLagged('/fast');
      expect(response.statusCode, 200);
      await response.drain<void>();
      // Put the loop behind while the timer runs, then let the late tick
      // run: the measured lag is far from zero when stop() is called.
      final blocked = Stopwatch()..start();
      while (blocked.elapsed < const Duration(milliseconds: 300)) {}
      await Future<void>.delayed(Duration.zero);
      expect(lagged.lagTimerActive, isTrue);
      expect(lagged.queueDelay, greaterThan(Duration.zero));

      await lagged.stop();
      expect(lagged.lagTimerActive, isFalse);
      expect(lagged.queueDelay, Duration.zero);
    });

    test('an engine without maxQueueDelay never starts the timer', () async {
      final response = await get('/fast');
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect(engine.lagTimerActive, isFalse);
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
