// What it costs to send a value to another isolate and back (ADR-031).
//
// ```bash
// dart run bin/isolate_payload.dart              # JIT
// dart compile exe bin/isolate_payload.dart -o build/isolate_payload && build/isolate_payload
// ```
//
// Prints the mean round trip, for a JSON document of 10, 1 000 and 10 000
// rows, of sending it as: a `Map` (deep-copied by the sender), a `String`
// (shared between the isolates of a process, not copied), a `Uint8List`
// (copied) and a `TransferableTypedData` (moved, then materialized). The
// numbers decide which form Daravel uses on the coordinator's path: see
// the table in `docs/guide/operations.md` ("Isolates").
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

void _echo(SendPort ready) {
  final inbox = RawReceivePort();
  inbox.handler = (Object? message) {
    final (Object? payload, SendPort reply) = message! as (Object?, SendPort);
    if (payload is TransferableTypedData) {
      final bytes = payload.materialize().asUint8List();
      reply.send(TransferableTypedData.fromList([bytes]));
    } else {
      reply.send(payload);
    }
  };
  ready.send(inbox.sendPort);
}

Future<void> main() async {
  final ready = Completer<SendPort>();
  final handshake = RawReceivePort(
    (Object? message) => ready.complete(message! as SendPort),
  );
  await Isolate.spawn(_echo, handshake.sendPort);
  final port = await ready.future;
  handshake.close();

  Future<Duration> roundTrip(Object? Function() make, int iterations) async {
    final reply = RawReceivePort();
    final watch = Stopwatch();
    for (var i = 0; i < iterations; i++) {
      final done = Completer<void>();
      reply.handler = (Object? result) {
        if (result is TransferableTypedData) {
          result.materialize();
        }
        done.complete();
      };
      final payload = make();
      watch.start();
      port.send((payload, reply.sendPort));
      await done.future;
      watch.stop();
    }
    reply.close();
    return Duration(microseconds: watch.elapsedMicroseconds ~/ iterations);
  }

  print('payload            map       string     bytes      ttd');
  for (final rows in [10, 1000, 10000]) {
    final map = <String, Object?>{
      'data': [
        for (var i = 0; i < rows; i++)
          <String, Object?>{
            'id': i,
            'name': 'user $i',
            'email': 'user$i@example.com',
            'active': true,
            'score': i * 1.5,
          },
      ],
    };
    final json = jsonEncode(map);
    final bytes = Uint8List.fromList(utf8.encode(json));
    final iterations = rows >= 10000 ? 200 : 2000;
    final asMap = await roundTrip(() => map, iterations);
    final asString = await roundTrip(() => json, iterations);
    final asBytes = await roundTrip(
      () => Uint8List.fromList(bytes),
      iterations,
    );
    final asTransferable = await roundTrip(
      () => TransferableTypedData.fromList([Uint8List.fromList(bytes)]),
      iterations,
    );
    final size = '${(bytes.length / 1024).round()} KB'.padRight(8);
    String us(Duration d) => '${d.inMicroseconds} us'.padRight(10);
    print(
      '$size ${'($rows rows)'.padRight(12)} '
      '${us(asMap)} ${us(asString)} ${us(asBytes)} ${us(asTransferable)}',
    );
  }
  Isolate.current.kill();
}
