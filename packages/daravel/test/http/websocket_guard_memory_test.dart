@Tags(['security', 'memory'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'support/raw_ws_client.dart';
import 'support/vm_heap.dart';

/// The WebSocket guard keeps a server's memory bounded against clients that
/// send without end or never read.
///
/// The server runs in a process of its own (support/guard_server.dart, one
/// isolate). What decides is what its guards hold, read from their own
/// counts (`GET /guard-stats`): the most a message being assembled, what
/// is held for a handler that does not read, and what waits to be written
/// reached during an attack stays within its bound at 1x and at 4x the
/// attack, and every count is back to zero once the connections ended.
/// What the server's heap holds after a full collection (read through its
/// VM service, `support/vm_heap.dart`) stays within what those counts
/// allow ([heapAllowance]), so memory the counts miss shows. Resident
/// memory is printed only: it moved by some 60 MiB between rounds of the
/// same attack on the same code (Linux), the allocator's pages, not data.
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

  /// The server, with its VM service open (port 0, on loopback) for its
  /// heap only: this test asks for it; the server does not open it itself.
  Future<(Process, int, VmHeap)> startServer({List<String>? into}) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--enable-vm-service=0',
      '--disable-service-auth-codes',
      await serverScript(),
    ]);
    final ready = Completer<int>();
    final service = Completer<String>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final listening = VmHeap.listening.firstMatch(line);
          if (listening != null && !service.isCompleted) {
            service.complete(listening.group(1));
          } else if (line.startsWith('PORT ') && !ready.isCompleted) {
            ready.complete(int.parse(line.substring(5)));
          } else if (line.startsWith('LOG ')) {
            into?.add(line.substring(4));
          }
        });
    process.stderr.drain<void>().ignore();
    final serverPort = await ready.future.timeout(const Duration(seconds: 60));
    // No heap, no test: failing here says why, rather than a fence on
    // resident memory that cannot tell data from the allocator's pages.
    final String address;
    try {
      address = await service.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill();
      throw StateError('The guard server printed no VM service address.');
    }
    return (process, serverPort, await VmHeap.connect(address));
  }

  late VmHeap heap;

  setUpAll(() async {
    (server, port, heap) = await startServer(into: logs);
  });

  tearDownAll(() async {
    await heap.close();
    server.kill();
  });

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
    const names = [
      'assembling',
      'held',
      'heldItems',
      'waiting',
      'queued',
      'unparsed',
      'pinned',
    ];
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

  /// Each connection's rest of a chunk ([connections] of them): part of
  /// one chunk, keeping at most that chunk's buffer, and no chunk read
  /// while it waited.
  void expectOneChunk(Map<String, int> c, {int connections = 1}) {
    expect(
      c['unparsedPeak'],
      lessThanOrEqualTo(connections * c['chunkPeak']!),
      reason: 'what is left unparsed is part of one chunk',
    );
    expect(
      c['pinnedPeak'],
      lessThanOrEqualTo(connections * c['chunkPeak']!),
      reason: 'a rest keeps at most the buffer of its chunk',
    );
    expect(
      c['chunksWhileUnparsed'],
      0,
      reason: 'no chunk read while a rest waited',
    );
  }

  /// That what an [attack] makes the guard keep does not grow with it: a
  /// warm-up round, then the attack at [scale] 1 and at 4, each with the
  /// peaks reset first; the peak of [count] in both stays within [bound],
  /// and everything is released after each. What the server's heap holds
  /// after a full collection, from after the warm-up (which loads the code
  /// the attack needs) to after the rounds, grows at most by what the
  /// counts allow ([heapAllowance]); its resident memory is printed only.
  Future<(int, int)> expectBounded(
    String name,
    Future<void> Function(int scale) attack, {
    required String count,
    required int bound,
  }) async {
    await attack(1);
    await expectReleased();
    final start = await rss();
    final heapStart = await heap.usedAfterGc();
    await resetPeaks();
    await attack(1);
    final countsOnce = await stats();
    final once = countsOnce['${count}Peak']!;
    await expectReleased();
    await resetPeaks();
    await attack(4);
    final countsFour = await stats();
    final four = countsFour['${count}Peak']!;
    await expectReleased();
    final grew = await rss() - start;
    final heapGrew = await heap.usedAfterGc() - heapStart;
    final allowance = heapAllowance(1, [countsOnce, countsFour]);
    // Printed always, for the numbers on every system CI runs: the rest of
    // a chunk kept unparsed is bounded by the largest chunk read, which
    // the system decides, so it is printed, not bounded by a number.
    String chunks(Map<String, int> c) =>
        'heldPeak ${c['heldPeak']}, unparsedPeak ${c['unparsedPeak']}, '
        'pinnedPeak ${c['pinnedPeak']}, chunkPeak ${c['chunkPeak']}';
    print(
      '$name: $count peak $once at 1x, $four at 4x (bound $bound); heap '
      '${heapGrew >> 10} KiB above the start (allowed ${allowance >> 10}); '
      'resident ${grew >> 20} MiB (printed only); '
      '1x: ${chunks(countsOnce)}; 4x: ${chunks(countsFour)}',
    );
    expect(once, lessThanOrEqualTo(bound), reason: '$count at 1x');
    expect(four, lessThanOrEqualTo(bound), reason: '$count at 4x');
    for (final c in [countsOnce, countsFour]) {
      expectOneChunk(c);
    }
    expect(heapGrew, lessThanOrEqualTo(allowance), reason: 'heap');
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

  /// [count] frames of a 64 KiB binary payload, in one buffer.
  Uint8List frames64k(int count) {
    final frame = RawWsClient.frame(0x2, Uint8List(65536));
    final all = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      all.add(frame);
    }
    return all.takeBytes();
  }

  /// One connection to [path] that writes [bytes] at once and then waits
  /// [wait] for the server to read what it will: what is held stays within
  /// [bound], what is left unparsed within the largest chunk read, and
  /// everything is released once the connection ended.
  Future<void> oneWrite(
    String name,
    String path,
    Uint8List bytes, {
    required int bound,
    Future<void> Function(RawWsClient client)? before,
    Duration wait = const Duration(seconds: 3),
  }) async {
    final client = await connect(path);
    await before?.call(client);
    await resetPeaks();
    client.socket.add(bytes);
    await Future<void>.delayed(wait);
    final counts = await stats();
    client.socket.destroy();
    await expectReleased();
    print(
      '$name: heldPeak ${counts['heldPeak']} (bound $bound), heldItemsPeak '
      '${counts['heldItemsPeak']}, unparsedPeak ${counts['unparsedPeak']}, '
      'pinnedPeak ${counts['pinnedPeak']}, chunkPeak ${counts['chunkPeak']}',
    );
    expect(counts['heldPeak'], lessThanOrEqualTo(bound));
    expectOneChunk(counts);
  }

  test('one write of 16 MiB of 64 KiB frames to a handler that does not '
      'read: held within the bound, the rest of a chunk left unparsed', () {
    return oneWrite(
      '64 KiB frames, 16 MiB',
      '/silent',
      frames64k(256),
      bound: _heldBound,
    );
  });

  test('one write of 4 MiB of full-size messages in fragments to a handler '
      'that does not read: held within the bound plus one message', () {
    final piece = Uint8List(16 << 10);
    final all = BytesBuilder(copy: false);
    for (var i = 0; i < 64; i++) {
      all
        ..add(RawWsClient.frame(0x2, piece, fin: false))
        ..add(RawWsClient.frame(0x0, piece, fin: false))
        ..add(RawWsClient.frame(0x0, piece, fin: false))
        ..add(RawWsClient.frame(0x0, piece));
    }
    return oneWrite(
      'fragmented messages, 4 MiB',
      '/silent',
      all.takeBytes(),
      bound: _heldBound + 65536 + 128,
    );
  });

  test('a connection whose TCP window grew (16 MiB read first), then 32 MiB '
      'in one write while the server is busy for 250 ms: held within the '
      'bound', () {
    return oneWrite(
      'warmed window, busy server, 32 MiB',
      '/warm?n=256&lag=250&hold=4000',
      frames64k(512),
      bound: _heldBound,
      before: (client) async {
        client.socket.add(frames64k(256));
        final ready = await client.nextMessage();
        expect(utf8.decode(ready.payload), 'READY');
      },
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('throughput to a handler that reads (printed, not bounded)', () async {
    // How fast a handler that reads gets a large stream, for the numbers on
    // every system CI runs: 64 MiB per run, the first run a warm-up.
    const total = 64 << 20;
    for (final size in [1 << 20, 4 << 10]) {
      final frame = RawWsClient.frame(0x2, Uint8List(size));
      final client = await connect('/sink?bytes=$total');
      final rates = <double>[];
      for (var run = 0; run < 6; run++) {
        final watch = Stopwatch()..start();
        for (var i = 0; i < total ~/ size; i++) {
          client.socket.add(frame);
          if (i % 64 == 63) {
            await client.socket.flush();
          }
        }
        final done = await client.nextMessage();
        expect(utf8.decode(done.payload), 'DONE');
        if (run > 0) {
          rates.add(total / watch.elapsedMicroseconds);
        }
      }
      client.socket.destroy();
      rates.sort();
      print(
        'throughput, ${size >> 10} KiB frames: median '
        '${rates[rates.length ~/ 2].toStringAsFixed(0)} MB/s, range '
        '${rates.first.toStringAsFixed(0)}-${rates.last.toStringAsFixed(0)} '
        'MB/s (5 runs of 64 MiB)',
      );
    }
    await expectReleased();
  }, timeout: const Timeout(Duration(minutes: 3)));

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
    final heapBefore = await heap.usedAfterGc();
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
    final counts = await stats();
    final peak = counts['assemblingPeak']!;
    final grew = await rss() - before;
    // The 200 clients have not closed their sockets yet: the server may
    // still hold each connection.
    final heapGrew = await heap.usedAfterGc() - heapBefore;
    final allowance = heapAllowance(200, [counts]);
    print(
      '200 connections: assembling peak $peak; heap ${heapGrew >> 10} KiB '
      'above the start (allowed ${allowance >> 10}); resident grew '
      '${grew >> 20} MiB (printed only)',
    );
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
    expect(heapGrew, lessThanOrEqualTo(allowance), reason: 'heap');
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
    // A server of its own, whose memory only this test moves.
    final (own, ownPort, ownHeap) = await startServer();
    addTearDown(() async {
      await ownHeap.close();
      own.kill();
    });
    Future<int> resident() async => int.parse(await get('/rss', on: ownPort));

    // One connection first, so the code its path needs is loaded.
    final warm = await RawWsClient.connect(ownPort, '/silent');
    warm.socket.add(RawWsClient.frame(0x1, const []));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await resetPeaks(on: ownPort);
    final before = await resident();
    final heapBefore = await ownHeap.usedAfterGc();
    final clients = <RawWsClient>[];
    for (var i = 0; i < 50; i++) {
      final client = await RawWsClient.connect(ownPort, '/silent');
      clients.add(client);
      client.socket.add(bytes);
    }
    // What the server reads before it holds TCP back.
    await Future<void>.delayed(const Duration(seconds: 2));
    final grew = await resident() - before;
    // While the 50 connections hold what they read.
    final heapGrew = await ownHeap.usedAfterGc() - heapBefore;
    final counts = await stats(on: ownPort);
    final allowance = heapAllowance(51, [counts]);
    print(
      'empty frames: held peak ${counts['heldPeak']}, items peak '
      '${counts['heldItemsPeak']}, unparsedPeak ${counts['unparsedPeak']}, '
      'pinnedPeak ${counts['pinnedPeak']}, chunkPeak ${counts['chunkPeak']}; '
      'heap ${heapGrew >> 10} KiB above the start (allowed '
      '${allowance >> 10}); resident grew ${grew >> 20} MiB (printed only), '
      'for 50 connections',
    );
    // An object per frame would be about 10 000 items per connection.
    expect(counts['heldItemsPeak'], lessThanOrEqualTo(50 * _heldItemsBound));
    expect(counts['heldPeak'], lessThanOrEqualTo(51 * _heldBound));
    expectOneChunk(counts, connections: 51);
    // Memory the counts miss shows here: every chunk read kept after it
    // was parsed took the heap past the allowance.
    expect(heapGrew, lessThanOrEqualTo(allowance), reason: 'heap');
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

/// How much the guard server's heap, after a full collection, may hold
/// above where it started, with [connections] open and the peaks in
/// [counts]: [_heapBase] plus [_heapPerConnection] each, plus
/// [_heapFactorPercent] of the most held and pinned (data the guard
/// counts, and what holding it costs beyond its bytes).
int heapAllowance(int connections, List<Map<String, int>> counts) {
  var counted = 0;
  for (final c in counts) {
    final both = c['heldPeak']! + c['pinnedPeak']!;
    if (both > counted) {
      counted = both;
    }
  }
  return _heapBase +
      connections * _heapPerConnection +
      counted * _heapFactorPercent ~/ 100;
}

/// What the server's heap moves by between two full collections with
/// nothing held: measured at 0.4 to 0.9 MiB above the start for 25 to 50
/// idle connections (Linux, Dart 3.13), the connections included.
const int _heapBase = 1 << 20;

/// One open WebSocket connection with nothing held: measured at about
/// 19 KB on the heap after a full collection (50 and 100 idle
/// connections, Linux and Windows).
const int _heapPerConnection = 32 << 10;

/// The heap after a full collection held 4.5 to 9.1 MiB, the connections
/// included, for 3.5 to 6.2 MB counted as held plus the unparsed rests
/// (50 connections of empty frames, Linux, three rounds; the buffers those
/// rests keep, counted now as pinned, were not counted then): at most
/// about 1.5 times with the rests alone, less with the buffers they keep.
const int _heapFactorPercent = 150;
