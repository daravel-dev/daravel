import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `ProcessSupervisor` (ADR-027): N copies of a program on consecutive
/// ports, each told its index, restarted when they exit, stopped together.
void main() {
  final script = p.join('test', 'server', 'fixtures', 'child_server.dart');

  Future<int> freePort() async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<Map<String, Object?>> ask(int port) async {
    final client = HttpClient();
    try {
      final request = await client.get('127.0.0.1', port, '/');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, Object?>;
    } finally {
      client.close(force: true);
    }
  }

  ProcessSupervisor supervisor(
    int port, {
    Map<String, String> env = const {},
  }) => ProcessSupervisor(
    executable: Platform.resolvedExecutable,
    arguments: [script],
    options: ServeOptions(
      host: '127.0.0.1',
      port: port,
      readyTimeout: const Duration(seconds: 60),
      shutdownTimeout: const Duration(seconds: 5),
    ),
    processes: 2,
    logger: Logger(minimumLevel: .warning),
    environment: env,
    handleSignals: false,
  );

  test(
    'runs two children on consecutive ports and stops them',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final port = await freePort();
      final manager = supervisor(port);
      await manager.start();
      expect(manager.ports, [port, port + 1]);
      expect(await ask(port), {'index': 0, 'port': port, 'count': '2'});
      expect(await ask(port + 1), {'index': 1, 'port': port + 1, 'count': '2'});
      expect(manager.upstreamBlock(), contains('server 127.0.0.1:$port;'));
      expect(
        manager.upstreamBlock(),
        contains('server 127.0.0.1:${port + 1};'),
      );
      await manager.stop();
      expect(manager.exitCode, 0);
      expect(ask(port), throwsA(isA<SocketException>()));
    },
  );

  test(
    'a child that exits is started again',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final port = await freePort();
      final marker = File(
        p.join(Directory.systemTemp.path, 'daravel_crash_$pid.marker'),
      );
      addTearDown(() {
        if (marker.existsSync()) {
          marker.deleteSync();
        }
      });
      final manager = supervisor(
        port,
        env: {'CRASH_INDEX': '1', 'CRASH_ONCE': marker.path},
      );
      // Child 1 exits once with code 3 before listening; the supervisor
      // respawns it after a second and readiness waits for the respawn.
      await manager.start();
      expect(marker.existsSync(), isTrue, reason: 'the first child crashed');
      expect(await ask(port + 1), containsPair('index', 1));
      await manager.stop();
      expect(manager.exitCode, 0);
    },
  );

  test(
    'children stop when the supervisor is killed outright',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final port = await freePort();
      final parent = await Process.start(Platform.resolvedExecutable, [
        p.join('test', 'server', 'fixtures', 'supervisor_main.dart'),
        '$port',
      ]);
      final lines = parent.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await lines.firstWhere((line) => line == 'ready');
      expect(await ask(port + 1), containsPair('index', 1));
      // No signal handler runs: TerminateProcess on Windows, SIGKILL here.
      parent.kill(ProcessSignal.sigkill);
      await parent.exitCode;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      for (final target in [port, port + 1]) {
        while (true) {
          try {
            await ask(target);
          } on Object {
            break;
          }
          if (DateTime.now().isAfter(deadline)) {
            fail('the child on port $target outlived its supervisor');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    },
  );
  test('selfArguments repeats the script under the dart VM', () {
    final args = selfArguments(['serve', '--port=1']);
    expect(args.last, '--port=1');
    expect(args, contains('serve'));
    if (Platform.script.toFilePath().endsWith('.dart')) {
      expect(args, contains(Platform.script.toFilePath()));
    }
  });
}
