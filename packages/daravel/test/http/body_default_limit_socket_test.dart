import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Without `BodyLimitsMiddleware` a request used to have no body limit at
/// all: a POST declaring (or streaming) gigabytes was buffered in memory
/// by the first `request.bytes()`. The engine now gives every request
/// `ServeOptions.maxBodyBytes` (`HTTP_MAX_BODY`, 50 MiB) to start with.
void main() {
  Future<ServerEngine> serve({int? maxBodyBytes, Env? env}) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.post(
              '/echo',
              (request) async => {'length': (await request.bytes()).length},
            );
            router
                .post(
                  '/wide',
                  (request) async => {'length': (await request.bytes()).length},
                )
                .bodyLimit(1 << 20);
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final engine = ServerEngine(
      app,
      env == null
          ? ServeOptions(
              host: '127.0.0.1',
              port: 0,
              handleSignals: false,
              maxBodyBytes: maxBodyBytes,
            )
          : ServeOptions.fromEnv(env, host: '127.0.0.1', port: 0),
      kernel: app.kernel,
      logger: Logger(minimumLevel: .critical),
    );
    await engine.start();
    addTearDown(engine.stop);
    return engine;
  }

  Future<void> released(ServerEngine engine) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (engine.inFlight != 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.inFlight, 0, reason: 'the slot is released');
  }

  /// Sends a body of [sent] bytes declaring [declared], and reads the reply
  /// until the server closes or goes quiet for a second.
  Future<String> post(
    ServerEngine engine,
    String path,
    int declared,
    int sent,
  ) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    socket.write(
      'POST $path HTTP/1.1\r\nHost: localhost\r\nContent-Length: $declared\r\n'
      'Connection: close\r\n\r\n',
    );
    socket.add(List<int>.filled(sent, 0x61));
    await socket.flush();
    final reply = await utf8.decoder
        .bind(
          socket.timeout(
            const Duration(seconds: 1),
            onTimeout: (sink) => sink.close(),
          ),
        )
        .join();
    socket.destroy();
    await released(engine);
    return reply;
  }

  test('a body above the default limit is refused with 413', () async {
    final engine = await serve(maxBodyBytes: 1 << 20);
    final reply = await post(engine, '/echo', (1 << 20) + 1, (1 << 20) + 1);
    expect(reply, startsWith('HTTP/1.1 413'));
    expect(reply, isNot(contains('1048576')), reason: 'not disclosed');
    expect(await post(engine, '/echo', 16, 16), contains('{"length":16}'));
  });

  test('a declared body far above the limit is never buffered', () async {
    final engine = await serve();
    // dart:io delivers no response before the declared body has arrived,
    // so the client sees nothing until it gives up; what matters is that
    // the engine refused it before reading (413 from the Content-Length
    // check), holds nothing, and frees the slot when the client goes.
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    socket.write(
      'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: ${60 << 20}\r\n'
      'Connection: close\r\n\r\n0123456789abcdef',
    );
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    socket.destroy();
    await released(engine);
    expect(await post(engine, '/echo', 16, 16), contains('{"length":16}'));
  });

  test(
    'the engine limit is a floor the route or middleware replaces',
    () async {
      final engine = await serve(maxBodyBytes: 8);
      expect(await post(engine, '/echo', 16, 16), startsWith('HTTP/1.1 413'));
      // RouteEntry.bodyLimit (1 MiB) replaces the engine's 8 bytes.
      expect(await post(engine, '/wide', 16, 16), contains('{"length":16}'));
    },
  );

  test('HTTP_MAX_BODY configures it; 0 means no limit', () async {
    final limited = await serve(env: Env.fromMap({'HTTP_MAX_BODY': '4'}));
    expect(await post(limited, '/echo', 16, 16), startsWith('HTTP/1.1 413'));
    final open = await serve(env: Env.fromMap({'HTTP_MAX_BODY': '0'}));
    expect(await post(open, '/echo', 16, 16), contains('{"length":16}'));
    expect(
      () => ServeOptions.fromEnv(Env.fromMap({'HTTP_MAX_BODY': '-1'})),
      throwsArgumentError,
    );
    expect(const ServeOptions().maxBodyBytes, 50 << 20);
  });
}
