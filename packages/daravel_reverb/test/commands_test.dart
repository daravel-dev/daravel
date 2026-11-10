import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/commands.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:test/test.dart';

final String secret = 's' * 32;

/// One directory for the process: a top-level initializer runs again in
/// every isolate, so `createTempSync` would give each worker its own (and
/// its own file cache, deaf to `reverb:restart`).
final String base = (Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}daravel_reverb_cmd_$pid',
)..createSync(recursive: true)).path;

/// A project's application: top-level, so worker isolates can build it.
Application cmdApp() => Application.configure(basePath: base)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_DATABASE': ':memory:',
      'METRICS_ENABLED': 'true',
      'QUEUE_SIGNAL_STORE': 'file',
      'REVERB_APP_ID': '42',
      'REVERB_APP_KEY': 'key-a',
      'REVERB_APP_SECRET': secret,
      'REVERB_DRAIN_SPREAD': '200ms',
    })
    .withLogLevel(LogLevel.critical)
    .withBroadcasting(authMiddleware: const [])
    .withReverb()
    .create();

Application withoutReverb() =>
    Application.configure(basePath: base)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();

Application withoutBroadcasting() =>
    Application.configure(basePath: base)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withReverb()
        .create();

Future<int?> dartisan(
  List<String> args, [
  ApplicationFactory factory = cmdApp,
]) {
  final runner = CommandRunner<int>('dartisan', 'test');
  for (final command in reverbCommands) {
    runner.addCommand(command(factory));
  }
  return runner.run(args);
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

const String sample = '''
# HELP reverb_connections Open Pusher connections, by app and worker isolate.
# TYPE reverb_connections gauge
reverb_connections{app="42",worker="daravel-worker-0"} 3
reverb_connections{app="42",worker="daravel-worker-1"} 2
reverb_connections{app="7",worker="daravel-worker-0"} 1
reverb_channels{app="42",type="presence"} 2
reverb_channels{app="42",type="public"} 4
reverb_messages_total{app="42",direction="in"} 10
reverb_messages_total{app="42",direction="out"} 25
reverb_rejected_total{reason="connection_quota"} 1
coordinator_messages_total 99
''';

void main() {
  test('ReverbReport: fan-out percentiles, slow clients, rate limits', () {
    final report = ReverbReport.parse('''
reverb_connections{app="42",worker="daravel-worker-0"} 1
reverb_fanout_seconds_bucket{app="42",le="0.0005"} 10
reverb_fanout_seconds_bucket{app="42",le="0.001"} 90
reverb_fanout_seconds_bucket{app="42",le="0.005"} 99
reverb_fanout_seconds_bucket{app="42",le="+Inf"} 100
reverb_fanout_seconds_bucket{app="42",le="0.0005"} 0
reverb_rate_limited_total{app="42"} 4
realtime_slow_clients_total{transport="websocket"} 2
realtime_slow_clients_total{transport="sse"} 9
''');
    final fanout = report.fanout['42']!;
    expect(fanout.count, 100);
    expect(fanout.p50, 1.0);
    expect(fanout.p95, 5.0);
    expect(report.rateLimited, {'42': 4});
    expect(report.slowClients, 2);
    expect(report.workers, {'daravel-worker-0': 1});
    final json = (report.toJson()['apps']! as Map)['42']! as Map;
    expect(json['fanout'], {'p50_ms': 1.0, 'p95_ms': 5.0, 'count': 100});
    expect(ReverbReport.parse('').fanout, isEmpty);
  });

  test('ReverbReport reads the reverb series of /metrics', () {
    final report = ReverbReport.parse(sample);
    expect(report.apps, ['42', '7']);
    expect(report.connectionsOf('42'), 5);
    expect(report.connections['42'], {
      'daravel-worker-0': 3,
      'daravel-worker-1': 2,
    });
    final json = report.toJson();
    expect((json['apps']! as Map)['42'], {
      'connections': 5,
      'workers': {'daravel-worker-0': 3, 'daravel-worker-1': 2},
      'channels': {'presence': 2, 'public': 4},
      'messages_in': 10,
      'messages_out': 25,
      'rate_limited': 0,
    });
    expect(json['rejected'], {'connection_quota': 1});
    final table = report.table();
    expect(table, contains('App 42: 5 connections, 2 presence, 4 public'));
    expect(table, contains('daravel-worker-1'));
    expect(table, contains('Refused: connection_quota 1'));
    expect(ReverbReport.parse('').table(), contains('No Pusher'));
  });

  test('reverb:start needs withReverb() and a Pusher server', () async {
    expect(await dartisan(['reverb:start'], withoutReverb), 1);
    expect(await dartisan(['reverb:start'], withoutBroadcasting), 1);
    expect(
      () => dartisan(['reverb:start', '--isolates=0']),
      throwsA(isA<UsageException>()),
    );
  });

  test('reverb:restart puts the signal', () async {
    expect(await dartisan(['reverb:restart']), 0);
    final app = cmdApp();
    await app.boot();
    addTearDown(app.shutdown);
    final at = await app.container.make<QueueManager>().signalStore!.store.get(
      reverbRestartKey,
    );
    expect(at, isA<int>());
  });

  test(
    'two isolates: stats per worker, and reverb:restart starts each again',
    () async {
      final port = await freePort();
      final supervisor = Supervisor(
        reverbServer(cmdApp),
        ServeOptions(
          host: '127.0.0.1',
          port: port,
          isolates: 2,
          handleSignals: false,
          shutdownTimeout: const Duration(seconds: 5),
          readyTimeout: const Duration(seconds: 60),
        ),
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await supervisor.start();
      addTearDown(supervisor.stop);

      final sockets = <WebSocket>[];
      final closed = <Future<void>>[];
      addTearDown(() async {
        for (final s in sockets) {
          await s.close();
        }
      });
      for (var i = 0; i < 8; i++) {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$port/app/key-a?protocol=7',
        );
        final done = Completer<void>();
        final established = Completer<void>();
        socket.listen((frame) {
          if ('$frame'.contains('connection_established') &&
              !established.isCompleted) {
            established.complete();
          }
        }, onDone: done.complete);
        await established.future.timeout(const Duration(seconds: 5));
        sockets.add(socket);
        closed.add(done.future);
      }

      // Each worker publishes its metrics to the coordinator every second;
      // /metrics, answered by either, merges them.
      final http = HttpClient();
      addTearDown(http.close);
      var report = ReverbReport.parse('');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (report.connectionsOf('42') < 8 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        report = ReverbReport.parse(
          await http
              .getUrl(Uri.parse('http://127.0.0.1:$port/metrics'))
              .then((r) => r.close())
              .then(utf8.decodeStream),
        );
      }
      expect(report.connectionsOf('42'), 8);
      expect(report.connections['42'], hasLength(2));
      expect(
        await dartisan([
          'reverb:stats',
          '--url=http://127.0.0.1:$port/metrics',
          '--json',
        ]),
        0,
      );

      expect(await dartisan(['reverb:restart']), 0);
      await Future.wait(closed).timeout(const Duration(seconds: 20));
      // Both workers came back without counting as crashes.
      final again = await WebSocket.connect(
        'ws://127.0.0.1:$port/app/key-a?protocol=7',
      ).timeout(const Duration(seconds: 20));
      sockets.add(again);
      expect(
        await again.first.timeout(const Duration(seconds: 5)),
        contains('connection_established'),
      );
      expect(supervisor.exitCode, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
