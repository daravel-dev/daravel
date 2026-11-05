import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

Uint8List pattern(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) i * 7 % 256]);

/// Sends [wire] to a port of this isolate and returns what arrives.
Future<Object?> roundTrip(Object wire) async {
  final arrived = Completer<Object?>();
  final port = RawReceivePort();
  port.handler = (Object? message) {
    port.close();
    arrived.complete(message);
  };
  port.sendPort.send(wire);
  return arrived.future;
}

void main() {
  const threshold = IsolatePayload.transferThreshold;

  test('the threshold is 32 KB', () {
    expect(threshold, 32 * 1024);
  });

  group('text', () {
    test('crosses as the String itself', () async {
      final text = 'x' * (threshold * 4);
      final wire = IsolatePayload.text(text).toWire();
      expect(wire, same(text));
      final arrived = await roundTrip(wire);
      expect(arrived, isA<String>());
      expect(IsolatePayload.fromWire(arrived!), text);
    });

    test('reads again: a String is not consumed', () {
      final wire = const IsolatePayload.text('hello').toWire();
      expect(IsolatePayload.fromWire(wire), 'hello');
      expect(IsolatePayload.fromWire(wire), 'hello');
    });
  });

  group('bytes below the threshold', () {
    test('cross as the Uint8List itself', () async {
      final bytes = pattern(threshold - 1);
      final payload = IsolatePayload.bytes(bytes) as BytesPayload;
      expect(payload.transfers, isFalse);
      final wire = payload.toWire();
      expect(wire, same(bytes));
      final arrived = await roundTrip(wire);
      expect(arrived, isA<Uint8List>());
      expect(IsolatePayload.fromWire(arrived!), bytes);
    });

    test('an empty list is fine', () async {
      final wire = IsolatePayload.bytes(Uint8List(0)).toWire();
      expect(IsolatePayload.fromWire((await roundTrip(wire))!), isEmpty);
    });
  });

  group('bytes from the threshold on', () {
    test('cross as a TransferableTypedData, byte for byte', () async {
      for (final length in [threshold, threshold + 1, 1 << 20]) {
        final bytes = pattern(length);
        final payload = IsolatePayload.bytes(bytes) as BytesPayload;
        expect(payload.transfers, isTrue);
        final wire = payload.toWire();
        expect(wire, isA<TransferableTypedData>());
        final arrived = await roundTrip(wire);
        expect(arrived, isA<TransferableTypedData>());
        final value = IsolatePayload.fromWire(arrived!);
        expect(value, isA<Uint8List>());
        expect(value, bytes, reason: '$length bytes');
      }
    });

    test('are materialized exactly once', () async {
      final wire = IsolatePayload.bytes(pattern(threshold)).toWire();
      final arrived = (await roundTrip(wire))!;
      expect(IsolatePayload.fromWire(arrived), hasLength(threshold));
      expect(() => IsolatePayload.fromWire(arrived), throwsArgumentError);
    });

    test('each toWire makes a new transferable', () {
      final payload = IsolatePayload.bytes(pattern(threshold));
      final first = payload.toWire();
      final second = payload.toWire();
      expect(first, isNot(same(second)));
      expect(IsolatePayload.fromWire(first), hasLength(threshold));
      expect(IsolatePayload.fromWire(second), hasLength(threshold));
    });
  });

  test('another wire form is refused', () {
    expect(() => IsolatePayload.fromWire(42), throwsArgumentError);
    expect(() => IsolatePayload.fromWire(<int>[1, 2]), throwsArgumentError);
  });

  test('Response.computed is the bytes, not a copy', () async {
    final pdf = pattern(threshold * 2);
    final response = Response.computed(
      pdf,
      contentType: 'application/pdf',
      status: 201,
      headers: {'content-disposition': 'inline; filename="a.pdf"'},
    );
    expect(response.status, 201);
    expect(response.headers.first('content-type'), 'application/pdf');
    expect(
      response.headers.first('content-disposition'),
      'inline; filename="a.pdf"',
    );
    expect((response.body as BytesBody).bytes, same(pdf));
    expect(await response.bodyBytes(), same(pdf));
  });
}
