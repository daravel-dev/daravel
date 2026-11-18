import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
// The guard's counts, for tests; not part of the public library.
import 'package:daravel/src/http/websocket_stats.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';
import 'support/websocket_counts.dart';

/// The guard parses a client's frames in pieces: it may stop in the middle
/// of a chunk read from TCP once enough is held for a handler that does
/// not read, and parse the rest later, joined to what came after. Seeded
/// random streams of frames (whole and fragmented messages, empty and tiny
/// frames, PINGs between fragments, a frame longer than a run, a close),
/// sent in random pieces, reach a handler that always reads and one that
/// pauses and resumes at random: both see the same messages, in the order
/// sent, the client gets a PONG for every PING and the same close, and
/// every count is back to zero.
///
/// `DIFF_SEEDS=<n>` runs more seeds than the 100 of CI (300 took 84 s on
/// Linux, 110 s on macOS and 134 s on Windows CI runners).
void main() {
  final seeds = int.tryParse(Platform.environment['DIFF_SEEDS'] ?? '') ?? 100;

  late Application app;
  late ServerEngine engine;

  /// What each handler saw, by connection id.
  final seen = <String, List<String>>{};

  String describe(Object? message) => switch (message) {
    final String text => 'T${text.length}:${_hash(utf8.encode(text))}',
    final List<int> bytes => 'B${bytes.length}:${_hash(bytes)}',
    _ => '?$message',
  };

  setUpAll(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws(
              '/reads',
              (socket, request) async {
                final into = seen[request.uri.queryParameters['id']!] = [];
                await socket
                    .listen((m) => into.add(describe(m)))
                    .asFuture<void>();
                into.add('done:${socket.closeCode}');
              },
              compress: false,
              maxPayloadBytes: 1 << 20,
              controlFrameBurst: 1 << 30,
              controlFramesPerSecond: 1 << 30,
            )
            ..ws(
              '/pauses',
              (socket, request) async {
                // Pauses and resumes at random, inside onData and from
                // timers, for long enough that what is held passes its
                // limit; starts listening late now and then.
                final id = request.uri.queryParameters['id']!;
                final into = seen[id] = [];
                final random = Random(int.parse(id.split('-').last));
                if (random.nextBool()) {
                  await Future<void>.delayed(
                    Duration(milliseconds: random.nextInt(60)),
                  );
                }
                final done = Completer<void>();
                late final StreamSubscription<dynamic> reading;
                reading = socket.listen((m) {
                  into.add(describe(m));
                  // Short pauses often, a long one rarely: each long one
                  // lets what arrives pass the held limit.
                  switch (random.nextInt(40)) {
                    case 0 || 1 || 2:
                      reading
                        ..pause()
                        ..resume();
                    case 3:
                      reading.pause(
                        Future<void>.delayed(
                          Duration(milliseconds: 5 + random.nextInt(30)),
                        ),
                      );
                    case 4 || 5 || 6:
                      reading.pause();
                      Timer(
                        Duration(milliseconds: random.nextInt(2)),
                        reading.resume,
                      );
                    case 7 || 8:
                      reading.pause(Future<void>.value());
                  }
                }, onDone: done.complete);
                await done.future;
                await reading.cancel();
                into.add('done:${socket.closeCode}');
              },
              compress: false,
              maxPayloadBytes: 1 << 20,
              controlFrameBurst: 1 << 30,
              controlFramesPerSecond: 1 << 30,
            ),
        )
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [MemoryHandler()]),
    );
    await engine.start();
  });

  tearDownAll(() async {
    await engine.stop();
    await app.shutdown();
  });

  /// Sends [stream] to [path] in random pieces; what the client got back:
  /// the PONG payloads and the close code.
  Future<(List<String>, int?)> run(
    String path,
    _Stream stream,
    Random random,
  ) async {
    final client = await RawWsClient.connect(engine.port!, path);
    final bytes = stream.bytes;
    var at = 0;
    while (at < bytes.length) {
      final size = switch (random.nextInt(4)) {
        0 => 1 + random.nextInt(20),
        1 => 100 + random.nextInt(5000),
        2 => 64 * 1024 - 64 + random.nextInt(128),
        _ => 1 + random.nextInt(bytes.length),
      };
      final end = min(bytes.length, at + size);
      client.socket.add(Uint8List.sublistView(bytes, at, end));
      at = end;
      await client.socket.flush();
      if (random.nextInt(4) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    final pongs = <String>[];
    int? close;
    while (true) {
      final frame = await client.next();
      if (frame.opcode == 0xA) {
        pongs.add(_hex(frame.payload));
      } else if (frame.opcode == 0x8) {
        close = frame.closeCode;
        break;
      }
    }
    client.socket.destroy();
    return (pongs, close);
  }

  test('$seeds seeded streams: the same messages, PONGs and close whether '
      'the handler reads or pauses', () async {
    var heldPast = 0;
    var unparsedSeen = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final stream = _Stream.generate(Random(seed));
      final expected = stream.messages;
      final pings = stream.pings;
      final results = <String, (List<String>, int?)>{};
      for (final path in ['/reads', '/pauses']) {
        WebSocketGuardStats.reset();
        final id = '${path.substring(1)}-$seed';
        results[path] = await run(
          '$path?id=$id',
          stream,
          Random(seed * 31 + path.length),
        );
        // The session ends once the close is answered.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (seen[id]?.lastOrNull?.startsWith('done:') != true &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final reason = 'seed $seed, $path';
        expect(seen[id], [...expected, 'done:1000'], reason: reason);
        await expectWebSocketCountsReleased();
        final counts = WebSocketGuardStats.toJson();
        expect(counts['chunksWhileUnparsed'], 0, reason: reason);
        expect(
          counts['unparsedPeak'],
          lessThanOrEqualTo(counts['chunkPeak']!),
          reason: reason,
        );
        if (counts['heldPeak']! > 64 << 10) {
          heldPast++;
        }
        if (counts['unparsedPeak']! > 0) {
          unparsedSeen++;
        }
      }
      expect(results['/reads']!.$1, pings, reason: 'seed $seed: PONGs');
      expect(results['/pauses']!.$1, pings, reason: 'seed $seed: PONGs');
      expect(results['/reads']!.$2, 1000, reason: 'seed $seed: close');
      expect(results['/pauses']!.$2, 1000, reason: 'seed $seed: close');
      seen.remove('reads-$seed');
      seen.remove('pauses-$seed');
    }
    print(
      '$seeds seeds: held past its limit in $heldPast connections, the rest '
      'of a chunk left unparsed in $unparsedSeen',
    );
    // The pausing handler made the guard hold and stop mid-chunk often
    // enough for the comparison to mean something.
    expect(heldPast, greaterThan(seeds ~/ 10));
    expect(unparsedSeen, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// A client's frames, masked, with the messages and PINGs they carry.
final class _Stream {
  _Stream(this.bytes, this.messages, this.pings);

  final Uint8List bytes;
  final List<String> messages;
  final List<String> pings;

  static _Stream generate(Random random) {
    final out = BytesBuilder(copy: false);
    final messages = <String>[];
    final pings = <String>[];
    Uint8List payload(int length) => Uint8List.fromList([
      for (var i = 0; i < length; i++) random.nextInt(256),
    ]);
    String text(int length) => String.fromCharCodes([
      for (var i = 0; i < length; i++) 0x61 + random.nextInt(26),
    ]);
    void ping() {
      final p = payload(random.nextInt(126));
      pings.add(_hex(p));
      out.add(RawWsClient.frame(0x9, p));
    }

    for (var k = 4 + random.nextInt(16); k > 0; k--) {
      switch (random.nextInt(6)) {
        case 0: // a whole text message
          final t = text(random.nextInt(300));
          messages.add('T${t.length}:${_hash(utf8.encode(t))}');
          out.add(RawWsClient.frame(0x1, utf8.encode(t)));
        case 1: // a whole binary message
          final b = payload(random.nextInt(4000));
          messages.add('B${b.length}:${_hash(b)}');
          out.add(RawWsClient.frame(0x2, b));
        case 2: // a fragmented text message, PINGs between fragments
          final parts = [
            for (var i = 2 + random.nextInt(4); i > 0; i--)
              text(random.nextInt(2000)),
          ];
          final whole = parts.join();
          messages.add('T${whole.length}:${_hash(utf8.encode(whole))}');
          for (var i = 0; i < parts.length; i++) {
            out.add(
              RawWsClient.frame(
                i == 0 ? 0x1 : 0x0,
                utf8.encode(parts[i]),
                fin: i == parts.length - 1,
              ),
            );
            if (i < parts.length - 1 && random.nextInt(3) == 0) {
              ping();
            }
          }
        case 3: // a run of empty and tiny frames
          for (var i = 5 + random.nextInt(400); i > 0; i--) {
            final t = text(random.nextInt(3));
            messages.add('T${t.length}:${_hash(utf8.encode(t))}');
            out.add(RawWsClient.frame(0x1, utf8.encode(t)));
          }
        case 4: // a frame longer than a run (64 KiB)
          final b = payload(64 * 1024 + random.nextInt(40 * 1024));
          messages.add('B${b.length}:${_hash(b)}');
          out.add(RawWsClient.frame(0x2, b));
        case _:
          ping();
      }
    }
    out.add(RawWsClient.frame(0x8, const [0x03, 0xE8]));
    return _Stream(out.takeBytes(), messages, pings);
  }
}

/// FNV-1a of [bytes], to compare messages without keeping them.
int _hash(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return h;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
