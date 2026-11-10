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
            router.get('/crash', (_) {
              Timer(const Duration(milliseconds: 50), Isolate.exit);
              return 'crashing';
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

  test('a crash after a restart still counts', () async {
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
      maxCrashesPerMinute: 1,
    );
    await supervisor.start();
    addTearDown(supervisor.stop);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    // No kept-alive connection: a dead isolate's sockets may stay open (only
    // the process closes them), so a pooled one would hang.
    Future<bool> get(String path) async {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port$path'),
        );
        request.persistentConnection = false;
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        await response.drain<void>();
        return response.statusCode == 200;
      } on IOException {
        return false;
      } on TimeoutException {
        return false;
      }
    }

    Future<void> up() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!await get('/whoami')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('The worker did not come back.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    // With maxCrashesPerMinute: 1, a restart counted as a crash would stop
    // the supervisor; it does not. The restart flag is not left set on the
    // respawned worker, so its first crash stops the supervisor (exit 1).
    expect(await get('/restart'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await up();
    expect(supervisor.exitCode, 0);
    expect(await get('/crash'), isTrue);
    await supervisor.done.timeout(const Duration(seconds: 30));
    expect(supervisor.exitCode, 1);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
