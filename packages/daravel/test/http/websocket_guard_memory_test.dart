@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// The WebSocket guard keeps a server's memory bounded against clients that
/// send without end or never read. The server runs in a process of its own
/// (support/guard_server.dart), so its memory is not mixed with the other
/// test files the runner runs at the same time.
void main() {
  late Process server;
  late int port;
  final logs = <String>[];

  setUpAll(() async {
    server = await Process.start(Platform.resolvedExecutable, [
      'test/http/support/guard_server.dart',
    ]);
    final ready = Completer<int>();
    server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('PORT ') && !ready.isCompleted) {
            ready.complete(int.parse(line.substring(5)));
          } else if (line.startsWith('LOG ')) {
            logs.add(line.substring(4));
          }
        });
    server.stderr.drain<void>().ignore();
    port = await ready.future.timeout(const Duration(seconds: 60));
  });

  tearDownAll(() => server.kill());

  /// A number the server answers on [path].
  Future<int> number(String path) async {
    final client = HttpClient();
    try {
      final request = await client.get('127.0.0.1', port, path);
      final response = await request.close();
      return int.parse(await utf8.decodeStream(response));
    } finally {
      client.close(force: true);
    }
  }

  /// The server process's resident memory now.
  Future<int> rss() => number('/rss');

  Future<RawWsClient> connect(String path) => RawWsClient.connect(port, path);

  test('fragments without end: closed at the limit, the server does not grow '
      'with what follows', () async {
    final before = await rss();
    final client = await connect('/echo');
    final piece = Uint8List(8192);
    client.send(0x1, piece, fin: false);
    // Up to 32 MB of fragments; the limit is 64 KiB.
    for (var i = 0; i < 4000 && !client.ended; i++) {
      client.send(0x0, piece, fin: false);
      if (i % 50 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    expect(await client.closeFrame(), 1009);
    final grew = await rss() - before;
    printOnFailure('server grew by ${grew >> 20} MiB');
    expect(grew, lessThan(32 << 20));
  });

  test('a client that pings and never reads: destroyed at the queue limit, '
      'the server bounded', () async {
    final before = await rss();
    final client = await connect('/flood');
    client.pauseReading();
    final ping = RawWsClient.frame(0x9, Uint8List(125));
    final burst = BytesBuilder();
    for (var i = 0; i < 4000; i++) {
      burst.add(ping);
    }
    final bytes = burst.takeBytes();
    // Up to 26 MB of pings, their pongs as much again.
    for (var i = 0; i < 50; i++) {
      try {
        client.socket.add(bytes);
        await client.socket.flush().timeout(const Duration(seconds: 2));
      } on Object {
        break;
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    bool slow() => logs.any((l) => l.contains('the client read too slowly'));
    while (!slow() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final grew = await rss() - before;
    printOnFailure('server grew by ${grew >> 20} MiB; log: $logs');
    expect(slow(), isTrue);
    expect(grew, lessThan(32 << 20));
    client.socket.destroy();
  });

  test('a handler that does not read: the client is held back by TCP, the '
      'server does not grow', () async {
    final before = await rss();
    final client = await connect('/silent');
    final message = RawWsClient.frame(0x2, Uint8List(1024));
    final burst = BytesBuilder();
    for (var i = 0; i < 1024; i++) {
      burst.add(message);
    }
    final bytes = burst.takeBytes();
    // Up to 64 MB, until TCP stops taking them.
    var sent = 0;
    for (var i = 0; i < 64; i++) {
      client.socket.add(bytes);
      try {
        await client.socket.flush().timeout(const Duration(milliseconds: 300));
        sent++;
      } on TimeoutException {
        break;
      }
    }
    final grew = await rss() - before;
    printOnFailure('sent $sent MiB; server grew by ${grew >> 20} MiB');
    expect(sent, lessThan(64), reason: 'TCP pushed back');
    expect(grew, lessThan(32 << 20));
    client.socket.destroy();
  });

  test(
    'a client that resets the connection while the server sends: the '
    'session ends, the server does not keep what it goes on sending',
    () async {
      final before = await rss();
      final ended = await number('/firehose-ended');
      // Sessions of the tests before (a handler that never reads keeps its
      // own until the server stops; dart:io reads nothing for it).
      final open = await number('/open');
      final client = await connect('/firehose');
      await client.next(); // the first MiB arrived
      // Data left unread when the socket closes makes the OS reset the
      // connection (RST): the server's next write fails.
      client.pauseReading();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      client.socket.destroy();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((await number('/open') > open ||
              await number('/firehose-ended') == ended) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await number('/open'), open, reason: 'the session ended');
      expect(
        await number('/firehose-ended'),
        ended + 1,
        reason: 'the handler saw the socket closed',
      );
      final grew = await rss() - before;
      printOnFailure('server grew by ${grew >> 20} MiB');
      // 100 MiB were to be sent; the socket buffers at most 8 MiB.
      expect(grew, lessThan(32 << 20));
    },
  );

  test('200 connections sending fragments without end: each closed, the '
      'server bounded', () async {
    final before = await rss();
    final clients = await Future.wait([
      for (var i = 0; i < 200; i++) connect('/echo'),
    ]);
    final piece = Uint8List(16384);
    for (final client in clients) {
      client.send(0x1, piece, fin: false);
    }
    // 1 MiB per connection, 200 MiB in all: the old code kept every
    // fragment; the guard closes each connection at 64 KiB.
    for (var round = 0; round < 64; round++) {
      for (final client in clients) {
        if (!client.ended) {
          client.send(0x0, piece, fin: false);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final codes = await Future.wait([
      for (final client in clients) client.closeFrame(),
    ]);
    final grew = await rss() - before;
    printOnFailure('server grew by ${grew >> 20} MiB');
    // Each connection was closed: with 1009, or, for a client still
    // sending when the guard's grace destroyed the socket and that had
    // not read the close frame yet, by a reset that drops it (null). These
    // clients never answer the close and go on sending, as an attacker
    // does; under load some read too late.
    expect(codes.toSet().difference({1009, null}), isEmpty);
    expect(codes, contains(1009));
    expect([for (final client in clients) client.ended], everyElement(true));
    expect(grew, lessThan(128 << 20));
    for (final client in clients) {
      client.socket.destroy();
    }
  });
}
