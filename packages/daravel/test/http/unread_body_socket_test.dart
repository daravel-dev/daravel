import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A request whose body nothing reads (a 404, a 401 from middleware, a
/// 413 from the declared length, a handler that ignores it) is answered
/// without waiting for that body (#144). `dart:io` reads such a body in
/// full before it writes the response, with no timeout, so a client that
/// sent its body slowly, or never, held the response and the in-flight
/// slot for as long as it kept its socket open.
void main() {
  late Application app;
  late Completer<void> gate;

  setUp(() async {
    gate = Completer<void>();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/ping', (request) => 'pong');
            router.post('/ignore', (request) => 'ignored');
            router.get('/block', (request) async {
              await gate.future;
              return 'released';
            });
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
  });

  Future<ServerEngine> serve({int? maxInFlight}) async {
    final engine = ServerEngine(
      app,
      ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        maxInFlight: maxInFlight,
      ),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    await engine.start();
    addTearDown(engine.stop);
    return engine;
  }

  Future<void> waitFor(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('$what within 10s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Opens a connection, sends a `POST` declaring [declared] body bytes
  /// and sends only [sent] of them; the socket stays open.
  Future<Socket> stalledPost(
    ServerEngine engine,
    String path, {
    required int declared,
    int sent = 10,
  }) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    socket
      ..write(
        'POST $path HTTP/1.1\r\nHost: localhost\r\n'
        'Accept: application/json\r\nContent-Length: $declared\r\n\r\n',
      )
      ..add(List<int>.filled(sent, 0x61));
    await socket.flush();
    return socket;
  }

  /// Everything the server sends until it closes the connection.
  Future<String> readUntilClosed(Socket socket) =>
      utf8.decoder.bind(socket).join().timeout(const Duration(seconds: 10));

  test('a 404 does not wait for a declared gigabyte', () async {
    final engine = await serve();
    final socket = await stalledPost(engine, '/missing', declared: 1 << 30);
    // The server answers and closes the connection while the client still
    // holds its end open, having sent 10 bytes.
    final reply = await readUntilClosed(socket);
    expect(reply, startsWith('HTTP/1.1 404'));
    await waitFor(() => engine.inFlight == 0, 'the slot is released');
  });

  test('a handler that ignores a stalled body answers at once', () async {
    final engine = await serve();
    final socket = await stalledPost(engine, '/ignore', declared: 1 << 20);
    final reply = await readUntilClosed(socket);
    expect(reply, startsWith('HTTP/1.1 200'));
    expect(reply, endsWith('ignored'));
    await waitFor(() => engine.inFlight == 0, 'the slot is released');
  });

  test('a small stalled body is waited for briefly, then closed', () async {
    final engine = await serve();
    final socket = await stalledPost(engine, '/missing', declared: 100);
    // After ServerEngine.unreadBodyDrainTimeout (1 s); without the fix the
    // server never answers and the read times out.
    final reply = await readUntilClosed(socket);
    expect(reply, startsWith('HTTP/1.1 404'));
    await waitFor(() => engine.inFlight == 0, 'the slot is released');
  });

  test('a small body that arrives keeps the connection open', () async {
    final engine = await serve();
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    final replies = StringBuffer();
    final sawSecond = Completer<void>();
    socket.listen((data) {
      replies.write(utf8.decode(data));
      if ('HTTP/1.1'.allMatches(replies.toString()).length == 2 &&
          replies.toString().endsWith('pong') &&
          !sawSecond.isCompleted) {
        sawSecond.complete();
      }
    });
    final body = 'x' * 1024;
    socket.write(
      'POST /missing HTTP/1.1\r\nHost: localhost\r\n'
      'Accept: application/json\r\nContent-Length: ${body.length}\r\n\r\n'
      '$body',
    );
    await socket.flush();
    await waitFor(
      () =>
          replies.toString().startsWith('HTTP/1.1 404') &&
          replies.toString().contains('could not be found'),
      'the 404 arrives',
    );
    // Same connection: it was kept alive.
    socket.write('GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n');
    await socket.flush();
    await sawSecond.future.timeout(const Duration(seconds: 10));
    expect(replies.toString(), contains('HTTP/1.1 200'));
  });

  test('stalled bodies do not take the in-flight slots', () async {
    final engine = await serve(maxInFlight: 2);
    final stalled = [
      await stalledPost(engine, '/missing', declared: 1 << 30),
      await stalledPost(engine, '/missing', declared: 1 << 30),
    ];
    for (final socket in stalled) {
      expect(await readUntilClosed(socket), startsWith('HTTP/1.1 404'));
    }
    await waitFor(() => engine.inFlight == 0, 'the slots are released');
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${engine.port}/ping'),
    )).close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    expect(engine.shedRequests, 0);
  });

  test('a shed POST is refused without waiting for its body', () async {
    final engine = await serve(maxInFlight: 1);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final held = client
        .getUrl(Uri.parse('http://127.0.0.1:${engine.port}/block'))
        .then((request) => request.close());
    await waitFor(() => engine.inFlight == 1, 'the slot is taken');
    final socket = await stalledPost(engine, '/ignore', declared: 1 << 30);
    final reply = await readUntilClosed(socket);
    expect(reply, startsWith('HTTP/1.1 503'));
    expect(engine.shedRequests, 1);
    gate.complete();
    await (await held).drain<void>();
  });
}
