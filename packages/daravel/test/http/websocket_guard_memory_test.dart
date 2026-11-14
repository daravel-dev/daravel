@Tags(['security', 'memory'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// The WebSocket guard keeps a server's memory bounded against clients that
/// send without end or never read.
///
/// The server runs in a process of its own (support/guard_server.dart, one
/// isolate). What decides is what its guards hold, read from their own
/// counts (`GET /guard-stats`): the most a message being assembled, what
/// is held for a handler that does not read, and what waits to be written
/// reached during an attack stays within its bound at 1x and at 4x the
/// attack, and every count is back to zero once the connections ended. The
/// resident memory of that process is only a coarse fence: it moved from
/// -222 to +15 MiB between the rounds of one attack (Linux, alone), more
/// than any finer bound could tell apart.
///
/// Heavy: it runs alone (`dart test --tags memory --run-skipped
/// --concurrency=1`), see dart_test.yaml.
void main() {
  late Process server;
  late int port;
  final logs = <String>[];

  /// support/guard_server.dart, found from this package's own root, not
  /// from the working directory.
  Future<String> serverScript() async {
    final lib = await Isolate.resolvePackageUri(
      Uri.parse('package:daravel/daravel.dart'),
    );
    return File.fromUri(lib!.resolve('../test/http/support/guard_server.dart'))
        .path;
  }

  Future<(Process, int)> startServer({List<String>? into}) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      await serverScript(),
    ]);
    final ready = Completer<int>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('PORT ') && !ready.isCompleted) {
            ready.complete(int.parse(line.substring(5)));
          } else if (line.startsWith('LOG ')) {
            into?.add(line.substring(4));
          }
        });
    process.stderr.drain<void>().ignore();
    return (process, await ready.future.timeout(const Duration(seconds: 60)));
  }

  setUpAll(() async {
    (server, port) = await startServer(into: logs);
  });

  tearDownAll(() => server.kill());

  Future<String> get(String path, {int? on}) async {
    final client = HttpClient();
    try {
      final request = await client.get('127.0.0.1', on ?? port, path);
      return await utf8.decodeStream(await request.close());
    } finally {
      client.close(force: true);
    }
  }

  /// A number the server answers on [path].
  Future<int> number(String path) async => int.parse(await get(path));

  /// The server process's resident memory now.
  Future<int> rss() => number('/rss');

  /// The guards' counts ([on] another server's port).
  Future<Map<String, int>> stats({int? on}) async => {
    for (final MapEntry(:key, :value)
        in (jsonDecode(await get('/guard-stats', on: on)) as Map).entries)
      '$key': value as int,
  };

  /// Peaks back to the current counts.
  Future<void> resetPeaks({int? on}) => get('/guard-stats/reset', on: on);

  /// Every count back to zero once the connections ended: a count left
  /// over is data left over.
  Future<void> expectReleased({int? on}) async {
    const names = ['assembling', 'held', 'heldItems', 'waiting', 'queued'];
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var now = await stats(on: on);
    while (names.any((n) => now[n] != 0) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      now = await stats(on: on);
    }
    expect(
      {for (final n in names) n: now[n]},
      {for (final n in names) n: 0},
      reason: 'released once the connections ended',
    );
  }

  Future<RawWsClient> connect(String path) => RawWsClient.connect(port, path);

  /// That what an [attack] makes the guard keep does not grow with it: a
  /// warm-up round, then the attack at [scale] 1 and at 4, each with the
  /// peaks reset first; the peak of [count] in both stays within [bound],
  /// and everything is released after each. The resident memory over the
  /// rounds stays within a coarse fence (macOS: a coarser one, as its
  /// runners move hundreds of MiB at once).
  Future<(int, int)> expectBounded(
    String name,
    Future<void> Function(int scale) attack, {
    required String count,
    required int bound,
  }) async {
    final start = await rss();
    await attack(1);
    await expectReleased();
    await resetPeaks();
    await attack(1);
    final once = (await stats())['${count}Peak']!;
    await expectReleased();
    await resetPeaks();
    await attack(4);
    final four = (await stats())['${count}Peak']!;
    await expectReleased();
    final grew = await rss() - start;
    // Printed always, for the numbers on every system CI runs.
    print(
      '$name: $count peak $once at 1x, $four at 4x (bound $bound); '
      'resident ${grew >> 20} MiB above the start',
    );
    expect(once, lessThanOrEqualTo(bound), reason: '$count at 1x');
    expect(four, lessThanOrEqualTo(bound), reason: '$count at 4x');
    expect(grew, lessThan((Platform.isMacOS ? 512 : 96) << 20));
    return (once, four);
  }

  /// 16 MB of fragments per [scale] after a first fragment, to [path].
  Future<void> fragmentsWithoutEnd(String path, int scale) async {
    final client = await connect(path);
    final piece = Uint8List(8192);
    client.send(0x1, piece, fin: false);
    for (var i = 0; i < 2000 * scale && !client.ended; i++) {
      client.send(0x0, piece, fin: false);
      if (i % 50 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (path == '/echo') {
      expect(await client.closeFrame(), 1009);
    } else {
      await client.socket.flush();
    }
    client.socket.destroy();
  }

  test('fragments without end: closed at the limit, what is assembled stays '
      'within it', () async {
    await expectBounded(
      'fragments without end',
      (scale) => fragmentsWithoutEnd('/echo', scale),
      count: 'assembling',
      // The route's limit: nothing past it is assembled.
      bound: 65536,
    );
  });

  test('the same without the limit grows with the attack: the counts tell '
      'a bound from none', () async {
    await resetPeaks();
    await fragmentsWithoutEnd('/echo-unlimited', 1);
    final once = (await stats())['assemblingPeak']!;
    await expectReleased();
    await resetPeaks();
    await fragmentsWithoutEnd('/echo-unlimited', 4);
    final four = (await stats())['assemblingPeak']!;
    await expectReleased();
    print('unlimited: assembling peak $once at 1x, $four at 4x');
    expect(once, greaterThan(65536), reason: 'past the bound of /echo');
    expect(four, greaterThan(once * 3), reason: 'about four times');
  });

  test('a client that pings and never reads: destroyed at the queue limit, '
      'what waits stays within it', () async {
    final ping = RawWsClient.frame(0x9, Uint8List(125));
    final burst = BytesBuilder();
    for (var i = 0; i < 4000; i++) {
      burst.add(ping);
    }
    final bytes = burst.takeBytes();
    bool slow(int count) =>
        logs.where((l) => l.contains('the client read too slowly')).length >=
        count;
    var rounds = 0;
    await expectBounded(
      'pings, never read',
      (scale) async {
        rounds++;
        final client = await connect('/flood');
        client.pauseReading();
        // Until the guard's queue overflows (how much the system's socket
        // buffers take in first varies), at most 64 bursts per scale.
        for (var i = 0; i < 64 * scale && !slow(rounds); i++) {
          try {
            client.socket.add(bytes);
            await client.socket.flush().timeout(const Duration(seconds: 2));
          } on Object {
            break;
          }
        }
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!slow(rounds) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(slow(rounds), isTrue, reason: 'log: $logs');
        client.socket.destroy();
      },
      count: 'waiting',
      // The route's maxBufferedBytes and the PONG that took it past.
      bound: 65536 + 127,
    );
  });

  test('a handler that does not read: the client is held back by TCP, what '
      'is held stays within the bound', () async {
    final message = RawWsClient.frame(0x2, Uint8List(1024));
    final burst = BytesBuilder();
    for (var i = 0; i < 1024; i++) {
      burst.add(message);
    }
    final bytes = burst.takeBytes();
    await expectBounded(
      'a handler that does not read',
      (scale) async {
        final client = await connect('/silent');
        // Up to 16 MB per scale, until TCP stops taking them.
        var sent = 0;
        for (var i = 0; i < 16 * scale; i++) {
          client.socket.add(bytes);
          try {
            await client.socket.flush().timeout(
              const Duration(milliseconds: 300),
            );
            sent++;
          } on TimeoutException {
            break;
          }
        }
        expect(sent, lessThan(16 * scale), reason: 'TCP pushed back');
        client.socket.destroy();
      },
      count: 'held',
      bound: _heldBound,
    );
  });

  test('a handler that does not read, sent messages of the full size in '
      'fragments: what is held and assembled stays within the bound', () async {
    // One message of exactly the route's limit (64 KiB) in four fragments.
    final piece = Uint8List(16 << 10);
    final message = BytesBuilder()
      ..add(RawWsClient.frame(0x2, piece, fin: false))
      ..add(RawWsClient.frame(0x0, piece, fin: false))
      ..add(RawWsClient.frame(0x0, piece, fin: false))
      ..add(RawWsClient.frame(0x0, piece));
    final once = message.takeBytes();
    final burst = BytesBuilder();
    for (var i = 0; i < 16; i++) {
      burst.add(once);
    }
    final bytes = burst.takeBytes(); // 1 MiB
    await expectBounded(
      'full-size fragmented messages, not read',
      (scale) async {
        final client = await connect('/silent');
        var sent = 0;
        for (var i = 0; i < 16 * scale; i++) {
          client.socket.add(bytes);
          try {
            await client.socket.flush().timeout(
              const Duration(milliseconds: 300),
            );
            sent++;
          } on TimeoutException {
            break;
          }
        }
        expect(sent, lessThan(16 * scale), reason: 'TCP pushed back');
        client.socket.destroy();
      },
      count: 'held',
      // Plus one whole message, assembled before it is held.
      bound: _heldBound + 65536 + 128,
    );
    expect((await stats())['assemblingPeak'], lessThanOrEqualTo(65536));
  });

  test('a client that resets the connection while the server sends: the '
      'session ends, what waits stays within the route bound', () async {
    final ended = await number('/firehose-ended');
    // Sessions of the tests before end once their clients are gone.
    final open = await number('/open');
    await resetPeaks();
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
    final counts = await stats();
    print(
      'firehose: queued peak ${counts['queuedPeak']}, waiting peak '
      '${counts['waitingPeak']}',
    );
    // 100 MiB were to be sent; the application's queue keeps at most the
    // route's 8 MiB, plus the 1 MiB message that took it past, and below
    // it the guard as much again.
    expect(counts['queuedPeak'], lessThanOrEqualTo((8 << 20) + (1 << 20)));
    expect(counts['waitingPeak'], lessThanOrEqualTo((8 << 20) + (1 << 20)));
    await expectReleased();
  });

  test('200 connections sending fragments without end: each closed, what '
      'is assembled stays within the limit of each', () async {
    final before = await rss();
    await resetPeaks();
    final clients = await Future.wait([
      for (var i = 0; i < 200; i++) connect('/echo'),
    ]);
    final piece = Uint8List(16384);
    for (final client in clients) {
      client.send(0x1, piece, fin: false);
    }
    // 1 MiB per connection, 200 MiB in all; the guard closes each
    // connection at 64 KiB.
    for (var round = 0; round < 64; round++) {
      for (final client in clients) {
        if (!client.ended && !client.closeReceived) {
          client.send(0x0, piece, fin: false);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final codes = await Future.wait([
      for (final client in clients) client.closeFrame(),
    ]);
    final peak = (await stats())['assemblingPeak']!;
    final grew = await rss() - before;
    print('200 connections: assembling peak $peak; grew ${grew >> 20} MiB');
    // Each connection was closed: with 1009, or, for a client still
    // sending when the guard's grace destroyed the socket and that had not
    // read the close frame yet, by a reset that drops it (null).
    final reset = codes.where((code) => code == null).length;
    printOnFailure('$reset of ${codes.length} connections reset');
    expect(codes.toSet().difference({1009, null}), isEmpty);
    expect(reset, lessThanOrEqualTo(codes.length ~/ 4));
    expect([for (final client in clients) client.ended], everyElement(true));
    // One server isolate: the peak is of all 200 together.
    expect(peak, lessThanOrEqualTo(200 * 65536));
    expect(grew, lessThan(128 << 20));
    for (final client in clients) {
      client.socket.destroy();
    }
    await expectReleased();
  });

  test('empty frames to a handler that does not read: held as a few '
      'buffers, not an object per frame', () async {
    // 50 connections, each 32 760 empty masked text frames of 6 bytes
    // (196 560 bytes), to a handler that never reads.
    final frames = BytesBuilder();
    for (var i = 0; i < 32760; i++) {
      frames.add(RawWsClient.frame(0x1, const []));
    }
    final bytes = frames.takeBytes();
    // A server of its own, whose resident memory only this test moves.
    final (own, ownPort) = await startServer();
    addTearDown(own.kill);
    Future<int> resident() async => int.parse(await get('/rss', on: ownPort));

    // One connection first, so the code its path needs is loaded.
    final warm = await RawWsClient.connect(ownPort, '/silent');
    warm.socket.add(RawWsClient.frame(0x1, const []));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await resetPeaks(on: ownPort);
    final before = await resident();
    final clients = <RawWsClient>[];
    for (var i = 0; i < 50; i++) {
      final client = await RawWsClient.connect(ownPort, '/silent');
      clients.add(client);
      client.socket.add(bytes);
    }
    // What the server reads before it holds TCP back.
    await Future<void>.delayed(const Duration(seconds: 2));
    final grew = await resident() - before;
    final counts = await stats(on: ownPort);
    print(
      'empty frames: held peak ${counts['heldPeak']}, items peak '
      '${counts['heldItemsPeak']}; grew ${grew >> 20} MiB for 50 connections',
    );
    // An object per frame would be about 10 000 items per connection.
    expect(counts['heldItemsPeak'], lessThanOrEqualTo(50 * _heldItemsBound));
    expect(counts['heldPeak'], lessThanOrEqualTo(51 * _heldBound));
    // An object per frame was 62-67 MiB (Linux); held as buffers, 2-16.
    expect(grew, lessThan((Platform.isMacOS ? 512 : 32) << 20));
    for (final client in [warm, ...clients]) {
      client.socket.destroy();
    }
    await expectReleased(on: ownPort);
  });
}

/// What one connection's guard may hold for a handler that does not read:
/// up to 64 KiB of cost before TCP is held back, plus the TCP chunk that
/// took it past (a chunk the server reads, assumed 64 KiB at most), each
/// item with its cost of 128.
const int _heldBound = (64 << 10) + (64 << 10) + 64 * 128;

/// The items of one connection's held data: small slices are merged into
/// buffers of 16 KiB, so a chunk of 64 KiB is a few of them.
const int _heldItemsBound = 64;
