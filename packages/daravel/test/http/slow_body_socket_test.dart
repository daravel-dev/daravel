import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A client that sends its headers and then trickles (or withholds) the
/// body it declared holds a request slot. The handler's read of that body
/// runs under the route timeout (`HTTP_REQUEST_TIMEOUT`), so the slot is
/// released with a 503 when it elapses, and the connection is closed
/// because the body was never read in full.
void main() {
  test('a withheld body is cut off by the request timeout', () async {
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
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final engine = ServerEngine(
      app,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        requestTimeout: Duration(milliseconds: 400),
      ),
      kernel: app.kernel,
      logger: Logger(minimumLevel: .critical),
    );
    await engine.start();
    addTearDown(engine.stop);

    final socket = await Socket.connect('127.0.0.1', engine.port!);
    socket.write(
      'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n'
      'Content-Type: application/octet-stream\r\n\r\n0123456789',
    );
    await socket.flush();
    final watch = Stopwatch()..start();
    final reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    socket.destroy();
    expect(reply, startsWith('HTTP/1.1 503'));
    expect(reply, contains('did not complete within'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    // The slot is free again and the server still answers.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (engine.inFlight != 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.inFlight, 0);
    final client = await Socket.connect('127.0.0.1', engine.port!);
    client.write(
      'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n'
      'Connection: close\r\n\r\nabc',
    );
    await client.flush();
    final ok = await utf8.decoder.bind(client).join();
    client.destroy();
    expect(ok, startsWith('HTTP/1.1 200'));
    expect(ok, endsWith('{"length":3}'));
  });
}
