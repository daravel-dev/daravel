import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  for (final shed in [true, false]) {
    test('draining responses close their connections, shed=$shed', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (r) {
              r.get('/hold', (_) async {
                entered.complete();
                await release.future;
                return 'held';
              });
              r.get('/ping', (_) => 'ok');
            },
          )
          .create();
      await app.boot();
      final engine = ServerEngine(
        app,
        ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          maxInFlight: shed ? 1 : null,
          drainGrace: const Duration(seconds: 1),
          shutdownTimeout: const Duration(seconds: 2),
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
      final peer = await Socket.connect('127.0.0.1', engine.port!);
      var text = '';
      final peerReading = peer.listen((bytes) {
        text += latin1.decode(bytes);
      }, onError: (Object _) {});
      final client = HttpClient();
      Future<void> waitHeader() async {
        final until = DateTime.now().add(const Duration(milliseconds: 800));
        while (!text.contains('\r\n\r\n') && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      try {
        peer.write('GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n');
        await peer.flush();
        await waitHeader();
        expect(text, contains('200 OK'));
        text = '';
        Future<void>? held;
        if (shed) {
          held = client
              .getUrl(Uri.parse('http://127.0.0.1:${engine.port}/hold'))
              .then((r) => r.close())
              .then((r) => r.drain<void>());
          held.ignore();
          await entered.future;
        }
        final stopping = engine.stop();
        await Future<void>(() {});
        peer.write(
          'GET /ping HTTP/1.1\r\nContent-Length: 0\r\n'
          'Host: localhost\r\n\r\n',
        );
        await peer.flush();
        await waitHeader();
        final header = text.split('\r\n\r\n').first;
        expect(header, contains(shed ? '503' : '200'));
        expect(header.toLowerCase().contains('connection: close'), isTrue);
        release.complete();
        if (held != null) await held;
        await stopping;
      } finally {
        if (!release.isCompleted) release.complete();
        await peerReading.cancel();
        peer.destroy();
        client.close(force: true);
        await engine.stop();
        await app.shutdown();
      }
    });
  }
}
