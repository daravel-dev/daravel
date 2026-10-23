import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Top-level factory: sendable to worker isolates (BLUEPRINT_V2 §5.2).
Application
supervisedApp() => Application.configure(basePath: Directory.systemTemp.path)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_DATABASE': ':memory:',
      'METRICS_ENABLED': 'true',
    })
    .withLogLevel(LogLevel.warning)
    .withRouting(
      apiPrefix: '',
      api: (router) {
        router.get('/whoami', (_) => {'isolate': Isolate.current.debugName});
        router.get('/limited', (_) => 'ok').middleware(const ['throttle:3,1']);
        router.get(
          '/hits',
          (_) async => {'hits': await Cache.store('process').increment('hits')},
        );
        router.get('/boom', (_) => throw StateError('boom'));
        router.get(
          '/scope',
          (req) => {'same': identical(AuthScope.request(), req)},
        );
      },
    )
    .create();

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test(
    'supervisor runs 2 workers on one port with process-scope state',
    () async {
      final port = await freePort();
      final supervisor = Supervisor(
        supervisedApp,
        ServeOptions(
          host: '127.0.0.1',
          port: port,
          isolates: 2,
          handleSignals: false,
          shutdownTimeout: const Duration(seconds: 5),
          readyTimeout: const Duration(seconds: 60),
        ),
        logger: Logger(minimumLevel: LogLevel.warning),
      );
      await supervisor.start();
      addTearDown(supervisor.stop);
      expect(supervisor.ports, [port, port]);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<(int, String)> get(String path) async {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        final response = await request.close();
        return (response.statusCode, await utf8.decodeStream(response));
      }

      final isolates = <String>{};
      for (var i = 0; i < 40; i++) {
        final (status, body) = await get('/whoami');
        expect(status, 200);
        isolates.add(
          (jsonDecode(body) as Map<String, Object?>)['isolate'] as String,
        );
      }
      expect(isolates, isNotEmpty);
      expect(isolates.every((n) => n.startsWith('daravel-worker-')), isTrue);

      // Rate limit is process-wide: exactly 3 succeed no matter which
      // worker answered.
      final statuses = <int>[];
      for (var i = 0; i < 5; i++) {
        statuses.add((await get('/limited')).$1);
      }
      expect(statuses, [200, 200, 200, 429, 429]);

      // Process cache is shared.
      var last = 0;
      for (var i = 0; i < 10; i++) {
        final (_, body) = await get('/hits');
        last = (jsonDecode(body) as Map<String, Object?>)['hits'] as int;
      }
      expect(last, 10);

      // The request is bound in its scope (guards rely on it).
      expect(jsonDecode((await get('/scope')).$2), {'same': true});

      // Metrics are merged across workers by the coordinator (snapshots are
      // published every second; the answering worker publishes fresh).
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final metrics = (await get("/metrics")).$2;
      expect(
        metrics,
        contains(
          'http_requests_total{method="GET",route="/whoami",status="200"} 40',
        ),
      );
      expect(
        RegExp(
          '^process_resident_memory_bytes ',
          multiLine: true,
        ).allMatches(metrics),
        hasLength(1),
      );

      // Handler errors are rendered, never kill a worker.
      expect((await get('/boom')).$1, 500);
      expect((await get('/whoami')).$1, 200);

      await supervisor.stop();
      expect(supervisor.exitCode, 0);
      await expectLater(get('/whoami'), throwsA(isA<SocketException>()));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
