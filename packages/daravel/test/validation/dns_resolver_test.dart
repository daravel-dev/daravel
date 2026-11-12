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

/// "It ends" in these tests: far above any timeout given here, and no
/// claim about how soon, which the machine's load decides.
const Duration _noHang = Duration(seconds: 30);

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
      // It ends: no tighter wall-clock bound. On a loaded machine the event
      // loop of this isolate may get no turn for seconds, and every timer,
      // the lookup's included, fires that late.
      expect(clock.elapsed, lessThan(_noHang));

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

  test('a server that does not listen: unknown within the timeout', () async {
    // A port that was just free. (Dart does not report ICMP "port
    // unreachable" on an unconnected UDP socket, on Windows or Linux: the
    // query goes unanswered. The error path is tested with a socket that
    // fails below.)
    final closed = await RawDatagramSocket.bind(loopback, 0);
    final port = closed.port;
    closed.close();
    final clock = Stopwatch()..start();
    final dns = SystemDnsResolver(
      timeout: const Duration(milliseconds: 500),
      nameservers: [(loopback, port)],
    );
    expect(await dns.mx('example.com'), isNull);
    expect(clock.elapsed, lessThan(_noHang));
  });

  for (final (label, socket) in [
    ('an error event', () => _FailingSocket(onReceive: false)),
    ('receive() throwing', () => _FailingSocket(onReceive: true)),
  ]) {
    test(
      'a socket error ($label) is unknown, never an error in the zone',
      () async {
        final clock = Stopwatch()..start();
        final dns = SystemDnsResolver(
          // An hour: answered at once by the error, or this test cannot
          // pass, however loaded the machine.
          timeout: const Duration(hours: 1),
          nameservers: [(loopback, 53)],
          bind: (_, _) async => socket(),
        );
        // An unhandled socket error would fail this test from its zone.
        expect(await dns.mx('example.com'), isNull);
        expect(clock.elapsed, lessThan(_noHang));
      },
    );
  }
}

/// A UDP socket whose query fails: an error event on its stream, or a
/// read event whose `receive()` throws, as an ICMP error would.
final class _FailingSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  _FailingSocket({required this.onReceive});

  final bool onReceive;
  final _events = StreamController<RawSocketEvent>();
  static const _error = SocketException('Connection reset by peer');

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    scheduleMicrotask(() {
      if (onReceive) {
        _events.add(RawSocketEvent.read);
      } else {
        _events.addError(_error);
      }
    });
    return buffer.length;
  }

  @override
  Datagram? receive() => onReceive ? throw _error : null;

  @override
  void close() => unawaited(_events.close());

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
