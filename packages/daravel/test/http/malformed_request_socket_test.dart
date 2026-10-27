import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Requests that `dart:io` accepts but that break while the engine builds
/// the [Request]: `HttpRequest.requestedUri` parses the `Host` and
/// `X-Forwarded-*` headers with `Uri.parse`, and [Headers] refuses control
/// characters. Each must be answered with 400 and must not take the server
/// (or, under a supervisor, the worker isolate) down with it.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/ping', (request) => 'pong');
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    log = MemoryHandler();
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [log]),
    );
    await engine.start();
    addTearDown(engine.stop);
  });

  Future<String> raw(List<int> bytes) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    socket.add(bytes);
    await socket.flush();
    final reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    socket.destroy();
    return reply;
  }

  Future<String> send(String request) => raw(latin1.encode(request));

  Future<void> expectStillServing() async {
    final reply = await send(
      'GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
    );
    expect(reply, startsWith('HTTP/1.1 200'));
    expect(reply, endsWith('pong'));
  }

  for (final (label, request) in <(String, String)>[
    (
      'an unterminated IPv6 literal in Host',
      'GET /ping HTTP/1.1\r\nHost: [::1\r\nConnection: close\r\n\r\n',
    ),
    (
      'a space in Host',
      'GET /ping HTTP/1.1\r\nHost: a b\r\nConnection: close\r\n\r\n',
    ),
    (
      'an illegal X-Forwarded-Proto',
      'GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Forwarded-Proto: ht tp\r\n'
          'Connection: close\r\n\r\n',
    ),
    (
      'an illegal X-Forwarded-Host',
      'GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Forwarded-Host: [bad\r\n'
          'Connection: close\r\n\r\n',
    ),
    (
      'a NUL byte in a header value',
      'GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Note: a\x00b\r\n'
          'Connection: close\r\n\r\n',
    ),
    (
      'invalid UTF-8 in a header value',
      'GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Note: \xff\xfe\xc3\r\n'
          'Connection: close\r\n\r\n',
    ),
  ]) {
    test('$label is answered with 400 and the server keeps serving', () async {
      final reply = await send(request);
      // dart:io itself drops a connection whose headers it cannot parse (the
      // NUL byte) without a reply; anything it lets through is answered.
      expect(
        reply,
        anyOf(startsWith('HTTP/1.1 400'), startsWith('HTTP/1.1 200'), isEmpty),
        reason:
            'the request must be answered or dropped by dart:io, '
            'never left hanging',
      );
      if (reply.startsWith('HTTP/1.1 400')) {
        expect(reply, contains('{"message":"Malformed request'));
        expect(reply, contains('connection: close'));
      }
      expect(engine.inFlight, 0, reason: 'the in-flight slot must be released');
      await expectStillServing();
      expect(
        log.records.where((r) => r.level == LogLevel.error),
        isEmpty,
        reason: 'a malformed request is not a server error',
      );
    });
  }

  test('a malformed request counts neither as served nor as shed', () async {
    await send('GET /ping HTTP/1.1\r\nHost: [::1\r\nConnection: close\r\n\r\n');
    expect(engine.shedRequests, 0);
    expect(engine.inFlight, 0);
  });
}
