import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A WebSocket handshake whose headers the server cannot read as one (a
/// handshake header given twice, a value that does not parse) is answered
/// 400 without any handshake header and closed: never left without an
/// answer, never an error in the server's own listener, during a drain
/// too.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  Future<void> serve() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..get('/ping', (_) => 'pong')
            ..get('/slow', (_) async {
              await Future<void>.delayed(const Duration(seconds: 2));
              return 'slow';
            })
            ..ws('/ws', (socket, _) {
              socket.listen(socket.add);
            })
            ..ws('/wsc', (socket, _) {
              socket.listen(socket.add);
            }, compress: true),
        )
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
      logger: Logger(handlers: [log = MemoryHandler()]),
    );
    await engine.start();
  }

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  /// The handshake for [path] with [extra] header lines, on [socket]
  /// (connected already); what came back until the server closed.
  Future<(String, bool)> answer(
    Socket socket,
    String path,
    String extra,
  ) async {
    socket.write(
      'GET $path HTTP/1.1\r\nHost: localhost\r\n$extra'
      'Sec-WebSocket-Version: 13\r\n\r\n',
    );
    await socket.flush();
    final bytes = <int>[];
    var closed = false;
    await socket
        .timeout(const Duration(seconds: 3))
        .forEach(bytes.addAll)
        .then<void>(
          (_) {
            closed = true;
          },
          // Still open after 3 s (an upgrade).
          onError: (Object _) {},
        );
    return (latin1.decode(bytes), closed);
  }

  const key = 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n';
  const upgrade = 'Upgrade: websocket\r\nConnection: Upgrade\r\n';

  void expectRefused(String reply, bool closed) {
    expect(reply, startsWith('HTTP/1.1 400'), reason: reply);
    final head = reply.split('\r\n\r\n').first.toLowerCase();
    expect(head, isNot(contains('upgrade: websocket')));
    expect(head, isNot(contains('sec-websocket-accept')));
    expect(head, isNot(contains('sec-websocket-extensions')));
    expect(head, contains('connection: close'));
    expect(closed, isTrue, reason: 'the connection is closed');
  }

  // Single-valued handshake headers given twice, and an extension header
  // the handshake cannot read as one value: refused.
  final duplicates = <String, String>{
    'Upgrade':
        'Upgrade: websocket\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\n$key',
    'Sec-WebSocket-Key': '$upgrade$key$key',
    'Sec-WebSocket-Version': '$upgrade${key}Sec-WebSocket-Version: 13\r\n',
    'Sec-WebSocket-Extensions':
        '$upgrade$key'
        'Sec-WebSocket-Extensions: permessage-deflate\r\n'
        'Sec-WebSocket-Extensions: permessage-deflate\r\n',
  };

  for (final MapEntry(key: header, value: lines) in duplicates.entries) {
    for (final path in ['/ws', '/wsc']) {
      test('$header twice ($path): 400 without handshake headers, closed, '
          'no error logged', () async {
        await serve();
        final socket = await Socket.connect('127.0.0.1', engine.port!);
        addTearDown(socket.destroy);
        final (reply, closed) = await answer(socket, path, lines);
        expectRefused(reply, closed);
        expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
      });
    }
  }

  // Lists RFC 6455 §4.1 allows to repeat (Sec-WebSocket-Protocol), or a
  // token list (Connection): a handshake like any other.
  final lists = <String, String>{
    'Connection':
        'Upgrade: websocket\r\nConnection: Upgrade\r\n'
        'Connection: Upgrade\r\n$key',
    'Sec-WebSocket-Protocol':
        '$upgrade$key'
        'Sec-WebSocket-Protocol: a\r\nSec-WebSocket-Protocol: b\r\n',
  };

  for (final MapEntry(key: header, value: lines) in lists.entries) {
    for (final path in ['/ws', '/wsc']) {
      test('$header twice ($path): upgraded, no error logged', () async {
        await serve();
        final socket = await Socket.connect('127.0.0.1', engine.port!);
        addTearDown(socket.destroy);
        socket.write(
          'GET $path HTTP/1.1\r\nHost: localhost\r\n$lines'
          'Sec-WebSocket-Version: 13\r\n\r\n',
        );
        await socket.flush();
        final head = await socket
            .map(latin1.decode)
            .firstWhere((text) => text.contains('\r\n'))
            .timeout(const Duration(seconds: 3));
        expect(head, startsWith('HTTP/1.1 101'));
        expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
      });
    }
  }

  test('one Sec-WebSocket-Extensions line with two offers on a route with '
      'compression: answered (upgraded or 400), never left open', () async {
    await serve();
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    final (reply, _) = await answer(
      socket,
      '/wsc',
      '$upgrade${key}Sec-WebSocket-Extensions: permessage-deflate, '
          'x-webkit-deflate-frame\r\n',
    );
    print('two offers in one line: ${reply.split('\r\n').first}');
    expect(
      reply,
      anyOf(startsWith('HTTP/1.1 101'), startsWith('HTTP/1.1 400')),
    );
    expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
  });

  test('an unclosed quoted value in Sec-WebSocket-Extensions on a route '
      'with compression: answered and closed, no error logged', () async {
    await serve();
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    final (reply, _) = await answer(
      socket,
      '/wsc',
      '$upgrade${key}Sec-WebSocket-Extensions: permessage-deflate; '
          'server_max_window_bits="10\r\n',
    );
    // Upgraded without compression, or refused: never without an answer.
    expect(
      reply,
      anyOf(startsWith('HTTP/1.1 101'), startsWith('HTTP/1.1 400')),
    );
    expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
  });

  test('during a drain: a handshake with Upgrade twice on a connection '
      'accepted before it is answered 400; the server stays up and answers '
      'the request in flight', () async {
    await serve();
    final port = engine.port!;
    final bad = await Socket.connect('127.0.0.1', port);
    addTearDown(bad.destroy);
    final good = await Socket.connect('127.0.0.1', port);
    addTearDown(good.destroy);
    // A request in flight keeps the drain going.
    good.write('GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n');
    await good.flush();
    final goodReply = good
        .timeout(const Duration(seconds: 6))
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
        .then(latin1.decode, onError: (Object e) => 'error: $e');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final stopping = engine.stop();
    final (reply, closed) = await answer(bad, '/ws', duplicates['Upgrade']!);
    expectRefused(reply, closed);
    expect(await goodReply, contains('slow'));
    await stopping;
    expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
  });

  test('during a drain: a plain request with Upgrade twice is answered as a '
      'plain request', () async {
    await serve();
    final port = engine.port!;
    final client = await Socket.connect('127.0.0.1', port);
    addTearDown(client.destroy);
    final slow = await Socket.connect('127.0.0.1', port);
    addTearDown(slow.destroy);
    slow.write('GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n');
    await slow.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final stopping = engine.stop();
    client.write(
      'GET /ping HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
      'Upgrade: websocket\r\n\r\n',
    );
    await client.flush();
    final reply = await client
        .timeout(const Duration(seconds: 3))
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
        .then(latin1.decode, onError: (Object e) => 'error: $e');
    expect(reply, startsWith('HTTP/1.1 200'), reason: reply);
    expect(reply.toLowerCase(), contains('connection: close'));
    await stopping;
    expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
  });
}
