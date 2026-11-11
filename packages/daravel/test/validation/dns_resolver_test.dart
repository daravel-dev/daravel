import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A nameserver on 127.0.0.1 that answers each MX query with what [reply]
/// returns for it (nothing when null), sent from [from] when given.
final class FakeNameserver {
  FakeNameserver._(this.socket);

  final RawDatagramSocket socket;
  int get port => socket.port;
  final List<Uint8List> queries = [];

  static Future<FakeNameserver> start(
    List<Uint8List> Function(Uint8List query, int clientPort) reply, {
    RawDatagramSocket? from,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final server = FakeNameserver._(socket);
    socket.listen((event) {
      final datagram = event == RawSocketEvent.read ? socket.receive() : null;
      if (datagram == null) {
        return;
      }
      server.queries.add(datagram.data);
      unawaited(
        sendAll(
          from ?? socket,
          reply(datagram.data, datagram.port),
          datagram.address,
          datagram.port,
        ),
      );
    });
    return server;
  }

  /// Sends each packet in turn. On Windows a send while the previous one is
  /// still in flight returns 0 and drops the packet: retry until it goes.
  static Future<void> sendAll(
    RawDatagramSocket socket,
    List<Uint8List> packets,
    InternetAddress address,
    int port,
  ) async {
    for (final packet in packets) {
      while (socket.send(packet, address, port) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  void close() => socket.close();
}

/// An answer to [query] with [flags] and one MX record for [exchange].
Uint8List mxAnswer(
  Uint8List query,
  String exchange, {
  int flags = 0x8180,
  int? id,
}) {
  final rid = id ?? (query[0] << 8 | query[1]);
  final name = [
    for (final l in exchange.split('.')) ...[l.length, ...l.codeUnits],
    0,
  ];
  return Uint8List.fromList([
    rid >> 8, rid & 0xff, flags >> 8, flags & 0xff, 0, 1, 0, 1, 0, 0, 0, 0, //
    ...query.sublist(12),
    0xc0, 12, 0, 15, 0, 1, 0, 0, 0, 60, 0, name.length + 2, 0, 10, //
    ...name,
  ]);
}

void main() {
  final loopback = InternetAddress.loopbackIPv4;

  test('the answer to our question, from the server asked', () async {
    final server = await FakeNameserver.start(
      (q, _) => [mxAnswer(q, 'mx.example.com')],
    );
    addTearDown(server.close);
    final dns = SystemDnsResolver(nameservers: [(loopback, server.port)]);
    expect(await dns.mx('example.com'), ['mx.example.com']);
  });

  test('a forged answer is ignored: another port, another id', () async {
    final forger = await RawDatagramSocket.bind(loopback, 0);
    addTearDown(forger.close);
    var forged = 0;
    late FakeNameserver server;
    server = await FakeNameserver.start((q, clientPort) {
      // From another port, with the right id: dropped by the client.
      forged = forger.send(mxAnswer(q, 'evil.example'), loopback, clientPort);
      return [
        mxAnswer(q, 'evil.example', id: (q[0] << 8 | q[1]) ^ 1),
        mxAnswer(q, 'mx.example.com'),
      ];
    });
    addTearDown(server.close);
    final dns = SystemDnsResolver(nameservers: [(loopback, server.port)]);
    expect(await dns.mx('example.com'), ['mx.example.com']);
    expect(forged, greaterThan(0), reason: 'the forged packet was sent');
    // Ids are random, not a counter.
    await dns.mx('example.com');
    expect(server.queries, hasLength(2));
    expect(
      server.queries[0].sublist(0, 2),
      isNot(server.queries[1].sublist(0, 2)),
    );
  });

  test(
    'silence: unknown within the timeout, the second server asked',
    () async {
      final silent = await FakeNameserver.start((q, _) => []);
      addTearDown(silent.close);
      final clock = Stopwatch()..start();
      final dns = SystemDnsResolver(
        timeout: const Duration(milliseconds: 400),
        nameservers: [(loopback, silent.port)],
      );
      expect(await dns.mx('example.com'), isNull);
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 1500)));

      final second = await FakeNameserver.start(
        (q, _) => [mxAnswer(q, 'mx.example.com')],
      );
      addTearDown(second.close);
      final both = SystemDnsResolver(
        timeout: const Duration(milliseconds: 400),
        nameservers: [(loopback, silent.port), (loopback, second.port)],
      );
      expect(await both.mx('example.com'), ['mx.example.com']);
    },
  );

  test('a truncated answer is unknown (A/AAAA decide)', () async {
    final server = await FakeNameserver.start(
      (q, _) => [mxAnswer(q, 'mx.example.com', flags: 0x8380)],
    );
    addTearDown(server.close);
    final dns = SystemDnsResolver(nameservers: [(loopback, server.port)]);
    expect(await dns.mx('example.com'), isNull);
  });

  test('no nameserver: unknown', () async {
    expect(await SystemDnsResolver(nameservers: const []).mx('x.com'), isNull);
  });
}
