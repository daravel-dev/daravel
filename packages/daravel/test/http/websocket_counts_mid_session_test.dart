import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/buffered_web_socket.dart';
import 'package:daravel/src/http/websocket_stats.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';
import 'support/websocket_counts.dart';

/// A socket below the send queue that never takes anything: what is added
/// stays queued.
final class _StalledSocket implements WebSocket {
  final Completer<void> _never = Completer<void>();

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) => _never.future;

  @override
  Future<dynamic> get done => _never.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The counts while a connection is still open, not only once it ended:
/// a message that ended is no longer counted as being assembled, and a send
/// queue given up is no longer counted as queued.
void main() {
  tearDown(expectWebSocketCountsReleased);

  int count(String name) => WebSocketGuardStats.toJson()[name]!;

  test('abandon() releases what waited in the send queue at once', () {
    // ignore: close_sinks (abandoned below: a socket whose connection is gone)
    final socket = BufferedWebSocket(
      _StalledSocket(),
      maxBufferedBytes: 1 << 20,
    );
    final before = count('queued');
    socket
      ..add(Uint8List(3000))
      ..add('x' * 1000);
    expect(count('queued') - before, 4000);
    socket.abandon();
    expect(count('queued'), before);
  });

  group('over a connection', () {
    late Application app;
    late ServerEngine engine;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            web: (router) => router.ws('/echo', (socket, _) {
              socket.listen(socket.add);
            }),
          )
          .create();
      await app.boot();
      engine = ServerEngine(
        app,
        const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(handlers: [MemoryHandler()]),
      );
      await engine.start();
    });

    tearDown(() async {
      await engine.stop();
      await app.shutdown();
    });

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a fragmented message that ended is no longer counted while the '
        'connection stays open', () async {
      final client = await RawWsClient.connect(engine.port!, '/echo');
      addTearDown(client.socket.destroy);
      client.send(0x1, Uint8List.fromList(List.filled(1500, 0x61)), fin: false);
      await until(() => count('assembling') == 1500);
      expect(count('assembling'), 1500, reason: 'the first fragment');
      client.send(0x0, Uint8List.fromList(List.filled(500, 0x62)));
      final echoed = await client.nextMessage();
      expect(echoed.payload, hasLength(2000));
      // Open still: the next message starts from nothing.
      expect(client.ended, isFalse);
      expect(count('assembling'), 0);
      client.send(0x1, Uint8List.fromList(List.filled(700, 0x63)), fin: false);
      await until(() => count('assembling') == 700);
      expect(count('assembling'), 700, reason: 'the second message alone');
      await client.close();
    });
  });
}
