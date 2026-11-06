import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Top-level factory: sendable to worker isolates. `/restart` answers,
/// then asks the application to be started again (`reverb:restart`).
Application restartingApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/whoami', (_) => {'isolate': Isolate.current.hashCode});
            router.get('/restart', (_) {
              final app = App.make<Application>();
              Timer(const Duration(milliseconds: 50), () {
                unawaited(app.restart());
              });
              return 'restarting';
            });
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
  test('a worker that asks to restart is spawned again at once, '
      'and restarts never count as a crash loop', () async {
    final port = await freePort();
    final supervisor = Supervisor(
      restartingApp,
      ServeOptions(
        host: '127.0.0.1',
        port: port,
        isolates: 1,
        handleSignals: false,
        shutdownTimeout: const Duration(seconds: 5),
        readyTimeout: const Duration(seconds: 60),
      ),
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    await supervisor.start();
    addTearDown(supervisor.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<String?> get(String path) async {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          await response.drain<void>();
          return null;
        }
        return await utf8.decodeStream(response);
      } on IOException {
        return null;
      }
    }

    Future<String> whoami() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        final body = await get('/whoami');
        if (body != null) {
          return body;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('The worker did not come back.');
    }

    final seen = <String>{await whoami()};
    // One more than maxCrashesPerMinute (5).
    for (var i = 0; i < 6; i++) {
      expect(await get('/restart'), 'restarting');
      // Until the old isolate is gone and the new one answers.
      var body = await whoami();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (seen.contains(body) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        body = await whoami();
      }
      expect(seen, isNot(contains(body)), reason: 'restart ${i + 1}');
      seen.add(body);
    }
    expect(supervisor.exitCode, 0);
    expect(seen, hasLength(7));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
