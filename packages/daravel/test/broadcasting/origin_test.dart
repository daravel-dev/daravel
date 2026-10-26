import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Application app;
  late ServerEngine engine;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'REVERB_APP_ID': '1',
          'REVERB_APP_KEY': 'key',
          'REVERB_APP_SECRET': 'secret',
          'REVERB_ALLOWED_ORIGINS': 'app.test,*.app.test',
        })
        .withBroadcasting()
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    await engine.start();
  });

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  Future<Map<String, Object?>> firstFrame(String? origin) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${engine.port}/app/key',
      headers: {'origin': ?origin},
    );
    final frame =
        jsonDecode(await socket.first as String) as Map<String, Object?>;
    await socket.close();
    return frame;
  }

  test('only the allowed origins connect (REVERB_ALLOWED_ORIGINS)', () async {
    expect(
      (await firstFrame('https://app.test'))['event'],
      'pusher:connection_established',
    );
    expect(
      (await firstFrame('https://admin.app.test'))['event'],
      'pusher:connection_established',
    );
    for (final origin in [
      'https://evil.test',
      'https://app.test.evil.com',
      null,
    ]) {
      final frame = await firstFrame(origin);
      expect(frame['event'], 'pusher:error', reason: origin);
      expect(jsonDecode(frame['data']! as String), {
        'code': 4009,
        'message': 'Origin not allowed',
      });
    }
  });

  test('without withBroadcasting keys there is no Pusher endpoint', () async {
    final noKeys = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withBroadcasting()
        .create();
    await noKeys.boot();
    expect(noKeys.router.routes.any((r) => r.path == '/app/{key}'), isFalse);
    await noKeys.shutdown();
  });
}
