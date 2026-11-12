import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Request header limits (`HTTP_MAX_HEADER_BYTES`,
/// `HTTP_MAX_HEADER_LINE_BYTES`, `HTTP_MAX_HEADERS`): above any of them
/// the engine answers 431 before routing, for a WebSocket handshake too.
/// The requests are written by hand, so every byte counted is known:
/// `dart:io` hands the engine the method, the target and each header's
/// name (lower case) and value.
void main() {
  late bool reached;

  Future<ServerEngine> serve(ServeOptions options) async {
    reached = false;
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/ok', (request) {
              reached = true;
              return {'ok': true};
            });
            router.ws('/socket', (socket, request) async {
              reached = true;
              await socket.close();
            });
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final engine = ServerEngine(
      app,
      options,
      kernel: app.kernel,
      logger: Logger(minimumLevel: .critical),
    );
    await engine.start();
    addTearDown(engine.stop);
    return engine;
  }

  ServeOptions options({
    int? maxHeaderBytes = ServeOptions.defaultMaxHeaderBytes,
    int? maxHeaderLineBytes = ServeOptions.defaultMaxHeaderLineBytes,
    int? maxHeaders = ServeOptions.defaultMaxHeaders,
  }) => ServeOptions(
    host: '127.0.0.1',
    port: 0,
    handleSignals: false,
    maxHeaderBytes: maxHeaderBytes,
    maxHeaderLineBytes: maxHeaderLineBytes,
    maxHeaders: maxHeaders,
  );

  /// Sends `GET <target>` with `host: x` and [headers], and returns the
  /// reply as text, read until the server closes or is quiet for a second.
  Future<String> send(
    ServerEngine engine,
    List<(String, String)> headers, {
    String target = '/ok',
  }) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    final received = BytesBuilder();
    final done = Completer<void>();
    socket
        .timeout(const Duration(seconds: 1), onTimeout: (sink) => sink.close())
        .listen(
          received.add,
          onError: (Object _) => done.isCompleted ? null : done.complete(),
          onDone: () => done.isCompleted ? null : done.complete(),
          cancelOnError: true,
        );
    socket.write(
      'GET $target HTTP/1.1\r\nhost: x\r\n'
      '${headers.map((h) => '${h.$1}: ${h.$2}\r\n').join()}\r\n',
    );
    await socket.flush();
    await done.future;
    socket.destroy();
    return latin1.decode(received.takeBytes());
  }

  int status(String reply) => int.parse(reply.split(' ')[1]);

  // GET + /ok + host + x: 3 + 3 + 4 + 1 bytes before the padding header.
  const base = 11;

  test('within the defaults: a long cookie and a long token pass', () async {
    final engine = await serve(options());
    final reply = await send(engine, [
      ('cookie', 'a' * 4000),
      ('authorization', 'Bearer ${'t' * 8000}'),
    ]);
    expect(status(reply), 200);
    expect(reached, isTrue);
  });

  test('the total: at the limit 200, one byte above 431', () async {
    final engine = await serve(options(maxHeaderBytes: 200));
    // x-pad (5) + value
    final room = 200 - base - 5;
    expect(status(await send(engine, [('x-pad', 'p' * room)])), 200);
    reached = false;
    final reply = await send(engine, [('x-pad', 'p' * (room + 1))]);
    expect(status(reply), 431);
    expect(reached, isFalse, reason: 'refused before routing');
    expect(reply.toLowerCase(), contains('connection: close'));
    expect(reply, contains('{"message":"Request Header Fields Too Large"}'));
  });

  test('the target counts in the total', () async {
    final engine = await serve(options(maxHeaderBytes: 200));
    final reply = await send(engine, const [], target: '/ok?${'q' * 200}');
    expect(status(reply), 431);
  });

  test('one header: at the limit 100, one byte above 431', () async {
    final engine = await serve(options(maxHeaderLineBytes: 100));
    expect(status(await send(engine, [('x-pad', 'p' * 95)])), 200);
    expect(status(await send(engine, [('x-pad', 'p' * 96)])), 431);
  });

  test('the default line limit refuses one header above 16 KiB', () async {
    final engine = await serve(options());
    expect(status(await send(engine, [('x-pad', 'p' * (16 * 1024 - 5))])), 200);
    expect(status(await send(engine, [('x-pad', 'p' * (16 * 1024 - 4))])), 431);
  });

  test('the number of headers, a repeated one counting each time', () async {
    final engine = await serve(options(maxHeaders: 3));
    // host + 2
    expect(status(await send(engine, [('x-a', '1'), ('x-b', '2')])), 200);
    expect(
      status(await send(engine, [('x-a', '1'), ('x-a', '2'), ('x-a', '3')])),
      431,
    );
  });

  test('null limits (HTTP_MAX_HEADER_*=0) turn the checks off', () async {
    final engine = await serve(
      ServeOptions.fromEnv(
        Env.fromMap({
          'HTTP_MAX_HEADER_BYTES': '0',
          'HTTP_MAX_HEADER_LINE_BYTES': '0',
          'HTTP_MAX_HEADERS': '0',
        }),
        host: '127.0.0.1',
        port: 0,
      ),
    );
    expect(engine.options.maxHeaderBytes, isNull);
    expect(engine.options.maxHeaderLineBytes, isNull);
    expect(engine.options.maxHeaders, isNull);
    final reply = await send(engine, [
      ('x-pad', 'p' * (64 * 1024)),
      for (var i = 0; i < 150; i++) ('x-$i', '$i'),
    ]);
    expect(status(reply), 200);
  });

  test('the log line gets the client header name and path cut to 64 '
      'characters, control and non-ASCII characters as ?', () {
    expect(ServerEngine.loggable('x-pad'), 'x-pad');
    final forged = 'x-a\r\n[ERROR] forged ${'z' * 100}';
    final logged = ServerEngine.loggable(forged);
    expect(logged, startsWith('x-a??[ERROR] forged '));
    expect(logged, hasLength(65));
    expect(logged, endsWith('…'));
    expect(logged.substring(0, 64), isNot(contains('\n')));
    expect(ServerEngine.loggable('café\u0000'), 'caf??');
  });

  test('fromEnv: defaults, and a negative limit is an error', () {
    final defaults = ServeOptions.fromEnv(
      Env.fromMap(const <String, String>{}),
    );
    expect(defaults.maxHeaderBytes, 32 * 1024);
    expect(defaults.maxHeaderLineBytes, 16 * 1024);
    expect(defaults.maxHeaders, 100);
    expect(
      () => ServeOptions.fromEnv(Env.fromMap(const {'HTTP_MAX_HEADERS': '-1'})),
      throwsArgumentError,
    );
  });

  test('a WebSocket handshake above the limit is refused before the '
      'upgrade', () async {
    final engine = await serve(options(maxHeaderLineBytes: 100));
    final handshake = [
      ('upgrade', 'websocket'),
      ('connection', 'Upgrade'),
      ('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ=='),
      ('sec-websocket-version', '13'),
    ];
    final upgraded = await send(engine, handshake, target: '/socket');
    expect(status(upgraded), 101, reason: 'the handshake itself is fine');
    reached = false;
    final refused = await send(engine, [
      ...handshake,
      ('x-pad', 'p' * 200),
    ], target: '/socket');
    expect(status(refused), 431);
    expect(reached, isFalse);
  });
}
