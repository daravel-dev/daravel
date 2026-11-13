import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A body that goes over its limit while it is read (sent `chunked`, so no
/// `Content-Length` refuses it first) is answered with the same `413` as a
/// declared one, and the connection is closed after it. Before, the read
/// cancelled the body and dart:io closed the connection with no response.
void main() {
  const kib = 1 << 10;
  final message = const PayloadTooLargeHttpException().message;

  Future<ServerEngine> serve({
    Map<String, String> env = const {},
    List<Middleware> global = const [],
  }) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
        .withLogLevel(LogLevel.critical)
        .withMiddleware((m) => m.use(global))
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.post(
              '/echo',
              (request) async => {'length': (await request.bytes()).length},
            );
            router.post(
              '/input',
              (request) async => {'keys': (await request.all()).length},
            );
            router
                .post(
                  '/narrow',
                  (request) async => {'length': (await request.bytes()).length},
                )
                .bodyLimit(64 * kib);
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final engine = ServerEngine(
      app,
      ServeOptions.fromEnv(Env.fromMap(env), host: '127.0.0.1', port: 0),
      kernel: app.kernel,
      logger: Logger(minimumLevel: .critical),
    );
    await engine.start();
    addTearDown(engine.stop);
    return engine;
  }

  /// What came back for [body] sent chunked to [path], read until the
  /// server closes (or goes quiet for 3 s), with whether it closed.
  Future<(String, bool)> sendChunked(
    ServerEngine engine,
    String path,
    String type,
    List<int> body, {
    bool keepSending = false,
  }) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    final received = BytesBuilder();
    final closed = Completer<bool>();
    socket
        .timeout(
          const Duration(seconds: 3),
          onTimeout: (sink) {
            if (!closed.isCompleted) {
              closed.complete(false);
            }
            sink.close();
          },
        )
        .listen(
          received.add,
          onError: (Object _) {
            if (!closed.isCompleted) {
              closed.complete(true);
            }
          },
          onDone: () {
            if (!closed.isCompleted) {
              closed.complete(true);
            }
          },
          cancelOnError: true,
        );
    socket.write(
      'POST $path HTTP/1.1\r\nHost: localhost\r\nContent-Type: $type\r\n'
      'Transfer-Encoding: chunked\r\n\r\n',
    );
    const piece = 16 * kib;
    Future<void> chunk(List<int> bytes) async {
      socket
        ..write('${bytes.length.toRadixString(16)}\r\n')
        ..add(bytes)
        ..write('\r\n');
      // A server that stopped reading never lets the flush complete.
      await Future.any([socket.flush(), closed.future]);
    }

    try {
      // Stops once the server closed (a flush may still be pending then).
      for (var at = 0; at < body.length && !closed.isCompleted; at += piece) {
        final end = at + piece < body.length ? at + piece : body.length;
        await chunk(body.sublist(at, end));
      }
      if (keepSending) {
        // A client that ignores the answer and keeps streaming.
        final filler = Uint8List(piece);
        while (!closed.isCompleted) {
          await chunk(filler);
        }
      } else if (!closed.isCompleted) {
        socket.write('0\r\n\r\n');
        await Future.any([socket.flush(), closed.future]);
      }
    } on SocketException {
      // The server closed the connection while the body was still going.
    }
    final byServer = await closed.future;
    socket.destroy();
    return (utf8.decode(received.takeBytes(), allowMalformed: true), byServer);
  }

  void expect413(String reply, String reason) {
    expect(reply, startsWith('HTTP/1.1 413'), reason: reason);
    expect(reply.toLowerCase(), contains('connection: close'), reason: reason);
    final body = reply.substring(reply.indexOf('\r\n\r\n') + 4);
    expect(jsonDecode(body), {'message': message}, reason: reason);
  }

  test('HTTP_MAX_BODY: 413, then the connection closes', () async {
    final engine = await serve(env: {'HTTP_MAX_BODY': '${256 * kib}'});
    final (over, closed) = await sendChunked(
      engine,
      '/echo',
      'application/octet-stream',
      Uint8List(256 * kib + 1),
    );
    expect413(over, 'HTTP_MAX_BODY');
    expect(closed, isTrue);
    final (under, _) = await sendChunked(
      engine,
      '/echo',
      'application/octet-stream',
      Uint8List(256 * kib),
    );
    expect(under, startsWith('HTTP/1.1 200'));
    expect(under, endsWith('{"length":${256 * kib}}'));
  });

  test('BodyLimitsMiddleware: JSON, form and multipart', () async {
    final engine = await serve(
      global: const [
        BodyLimitsMiddleware(json: 32 * kib, form: 32 * kib, other: 32 * kib),
      ],
    );
    final json = utf8.encode('{"pad":"${'a' * (32 * kib)}"}');
    expect413(
      (await sendChunked(engine, '/input', 'application/json', json)).$1,
      'json',
    );
    expect413(
      (await sendChunked(
        engine,
        '/input',
        'application/x-www-form-urlencoded',
        utf8.encode('pad=${'a' * (32 * kib)}'),
      )).$1,
      'form',
    );
    // Multipart is read as a stream (bodyStream), not buffered.
    const boundary = 'xyz';
    final multipart = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="pad"\r\n\r\n'
      '${'a' * (32 * kib)}\r\n--$boundary--\r\n',
    );
    expect413(
      (await sendChunked(
        engine,
        '/input',
        'multipart/form-data; boundary=$boundary',
        multipart,
      )).$1,
      'multipart',
    );
    final small = utf8.encode('{"name":"x"}');
    expect(
      (await sendChunked(engine, '/input', 'application/json', small)).$1,
      startsWith('HTTP/1.1 200'),
    );
  });

  test("a route's bodyLimit", () async {
    final engine = await serve();
    expect413(
      (await sendChunked(
        engine,
        '/narrow',
        'application/octet-stream',
        Uint8List(64 * kib + 1),
      )).$1,
      'bodyLimit',
    );
  });

  test('a body far over the limit: the client gets the 413', () async {
    // Beyond what the server throws away before it answers
    // (Request.refusedBodyDiscardBytes), so the body is paused, answered,
    // and its rest read off after the answer.
    final engine = await serve(env: {'HTTP_MAX_BODY': '${64 * kib}'});
    for (var i = 0; i < 5; i++) {
      final (reply, closed) = await sendChunked(
        engine,
        '/echo',
        'application/octet-stream',
        Uint8List(2 << 20),
      );
      expect413(reply, 'round $i');
      expect(closed, isTrue, reason: 'round $i');
    }
  });

  test('a client that keeps sending after the 413 is cut off, and the '
      'server goes on serving without growing', () async {
    final engine = await serve(env: {'HTTP_MAX_BODY': '${64 * kib}'});
    final before = ProcessInfo.currentRss;
    final watch = Stopwatch()..start();
    for (var i = 0; i < 4; i++) {
      // Whether such a client still reads the 413 depends on when it reads:
      // the server stops reading after its linger and resets the
      // connection, as Go and nginx do. Not asserted here.
      final (_, closed) = await sendChunked(
        engine,
        '/echo',
        'application/octet-stream',
        Uint8List(64 * kib + 1),
        keepSending: true,
      );
      expect(closed, isTrue, reason: 'closed by the server, round $i');
    }
    // Each connection lasts the server's linger (1 s) at most, not as long
    // as the client keeps sending.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    final grown = ProcessInfo.currentRss - before;
    expect(grown, lessThan(64 << 20), reason: 'RSS grew $grown bytes');
    // The isolate is free: a normal request is answered at once.
    final (ok, _) = await sendChunked(
      engine,
      '/echo',
      'application/octet-stream',
      Uint8List(10),
    );
    expect(ok, startsWith('HTTP/1.1 200'));
  });
}
