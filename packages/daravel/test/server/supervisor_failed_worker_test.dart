import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A provider whose boot throws: the worker reports WorkerFailed and
/// exits on its own.
final class _FailsToBoot extends ServiceProvider {
  @override
  Future<void> boot(Container container) async {
    throw StateError('the database is down');
  }
}

/// Top-level factory: sendable to worker isolates.
Application failingApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withProviders([_FailsToBoot()])
        .create();

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// A worker that fails to boot is reported once: its readiness future
/// fails with the worker's error, and its own exit is not counted as a
/// second crash (which used to schedule a second respawn for the same
/// index). stop() afterwards has nothing to wait for.
void main() {
  test('a worker that fails to boot is reported once and forgotten', () async {
    final supervisor = Supervisor(
      failingApp,
      ServeOptions(
        host: '127.0.0.1',
        port: await freePort(),
        isolates: 1,
        handleSignals: false,
        shutdownTimeout: const Duration(seconds: 10),
        readyTimeout: const Duration(seconds: 30),
      ),
      logger: Logger(minimumLevel: .critical),
    );
    await expectLater(
      supervisor.start(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(startsWith('Worker 0 failed:'), contains('database is down')),
        ),
      ),
    );
    // The worker's own exit arrives after the failure; it must not be a
    // crash to respawn, and nothing holds stop().
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final watch = Stopwatch()..start();
    await supervisor.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(supervisor.exitCode, 0);
    expect(supervisor.ports, isEmpty, reason: 'no second isolate for index 0');
  });
}
