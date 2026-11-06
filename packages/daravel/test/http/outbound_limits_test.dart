import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A raw TCP server that reads a request head and then does what [answer]
/// says with the socket. [closed] completes for each connection when the
/// client closes or resets it: what a test checks to see that nothing is
/// left open on the server's side.
final class RawUpstream {
  RawUpstream._(this._server, this.answer);

  static Future<RawUpstream> start(void Function(Socket socket) answer) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = RawUpstream._(server, answer);
    server.listen(upstream._accept);
    return upstream;
  }

  final ServerSocket _server;
  final void Function(Socket socket) answer;
  final List<Completer<void>> _closed = [];
  final List<Timer> _timers = [];

  int get port => _server.port;

  /// Completes when the first connection is closed by the client.
  Future<void> get firstClosed async {
    while (_closed.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return _closed.first.future;
  }

  int get connections => _closed.length;
  int get open => _closed.where((c) => !c.isCompleted).length;

  void every(Duration period, void Function() tick) =>
      _timers.add(Timer.periodic(period, (_) => tick()));

  void _accept(Socket socket) {
    // Writes after the client closed fail on `done`, not where written.
    socket.done.ignore();
    final closed = Completer<void>();
    _closed.add(closed);
    var answered = false;
    final head = <int>[];
    socket.listen(
      (data) {
        head.addAll(data);
        if (!answered && latin1.decode(head).contains('\r\n\r\n')) {
          answered = true;
          answer(socket);
        }
      },
      onDone: () {
        if (!closed.isCompleted) {
          closed.complete();
        }
      },
      onError: (Object _) {
        if (!closed.isCompleted) {
          closed.complete();
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    await _server.close();
  }
}

void main() {
  late HttpClientFactory factory;
  late List<RawUpstream> upstreams;

  setUp(() {
    factory = HttpClientFactory();
    upstreams = [];
  });
  tearDown(() async {
    factory.close();
    for (final upstream in upstreams) {
      await upstream.close();
    }
  });

  Future<RawUpstream> upstream(void Function(Socket socket) answer) async {
    final started = await RawUpstream.start(answer);
    upstreams.add(started);
    return started;
  }

  group('HttpClientFactory', () {
    test(
      'a timeout mid-body closes the connection and stops reading',
      () async {
        late RawUpstream endless;
        endless = await upstream((socket) {
          socket.write(
            'HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n'
            'content-type: text/plain\r\n\r\n',
          );
          endless.every(const Duration(milliseconds: 10), () {
            if (endless.open == 0) {
              return; // The client is gone: nothing more to send.
            }
            try {
              socket.write('400\r\n${'x' * 1024}\r\n');
            } catch (_) {}
          });
        });
        await expectLater(
          factory
              .request()
              .timeout(const Duration(milliseconds: 300))
              .get('http://127.0.0.1:${endless.port}/stream'),
          throwsA(
            isA<ConnectionException>().having(
              (e) => e.isTimeout,
              'timeout',
              true,
            ),
          ),
        );
        await endless.firstClosed.timeout(const Duration(seconds: 10));
      },
    );

    test('a timeout before any answer closes the connection', () async {
      final silent = await upstream((_) {});
      await expectLater(
        factory
            .request()
            .timeout(const Duration(milliseconds: 200))
            .get('http://127.0.0.1:${silent.port}/'),
        throwsA(isA<ConnectionException>()),
      );
      await silent.firstClosed.timeout(const Duration(seconds: 10));
    });

    test('a body over maxResponseSize throws and closes, declared or '
        'streamed', () async {
      final declared = await upstream((socket) {
        socket.write('HTTP/1.1 200 OK\r\ncontent-length: 5000\r\n\r\n');
      });
      await expectLater(
        factory
            .request()
            .maxResponseSize(1000)
            .get('http://127.0.0.1:${declared.port}/'),
        throwsA(
          isA<ResponseTooLargeException>().having(
            (e) => e.maxBytes,
            'maxBytes',
            1000,
          ),
        ),
      );
      await declared.firstClosed.timeout(const Duration(seconds: 10));

      final streamed = await upstream((socket) {
        socket.write('HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n');
        for (var i = 0; i < 4; i++) {
          socket.write('400\r\n${'y' * 1024}\r\n');
        }
        // No last chunk: the response would never end on its own.
      });
      factory.maxResponseBytes = 2048;
      await expectLater(
        factory.request().get('http://127.0.0.1:${streamed.port}/'),
        throwsA(isA<ResponseTooLargeException>()),
      );
      await streamed.firstClosed.timeout(const Duration(seconds: 10));
    });

    test('the default limit is generous, and bodyBytes keeps binary '
        'bodies', () async {
      expect(factory.maxResponseBytes, 32 * 1024 * 1024);
      final bytes = Uint8List.fromList([0, 255, 128, 10, 13, 200]);
      final binary = await upstream((socket) {
        socket
          ..write(
            'HTTP/1.1 200 OK\r\ncontent-length: ${bytes.length}\r\n'
            'connection: close\r\n\r\n',
          )
          ..add(bytes);
        unawaited(socket.flush().then((_) => socket.close()));
      });
      final response = await factory.request().get(
        'http://127.0.0.1:${binary.port}/',
      );
      expect(response.bodyBytes, bytes);
      expect(ClientResponse(200, 'é').bodyBytes, utf8.encode('é'));
    });

    test('a TLS handshake failure is a ConnectionException', () async {
      // Plain HTTP where TLS is expected.
      final plain = await upstream((socket) {
        socket.write('HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n');
      });
      final notTls = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => notTls.close(force: true));
      notTls.listen((request) => request.response.close());
      for (final port in [plain.port, notTls.port]) {
        await expectLater(
          factory
              .request()
              .timeout(const Duration(seconds: 10))
              .get('https://127.0.0.1:$port/'),
          throwsA(isA<ConnectionException>()),
        );
      }
    });
  });

  group('UpstreamProxy', () {
    test('a 504 closes the upstream connection', () async {
      final hung = await upstream((_) {});
      final proxy = UpstreamProxy(
        Uri.parse('http://127.0.0.1:${hung.port}'),
        timeout: const Duration(milliseconds: 200),
      );
      addTearDown(proxy.close);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          proxy.forward(Request.fake(path: '/slow')),
          throwsA(isA<HttpException>().having((e) => e.status, 'status', 504)),
        );
      }
      await hung.firstClosed.timeout(const Duration(seconds: 10));
      // Every timed-out forward let go of its socket, before close().
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (hung.open > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(hung.connections, 3);
      expect(hung.open, 0);
    });

    test('shadow() closes the upstream connection on a timeout', () async {
      final hung = await upstream((_) {});
      final proxy = UpstreamProxy(
        Uri.parse('http://127.0.0.1:${hung.port}'),
        timeout: const Duration(milliseconds: 200),
      );
      addTearDown(proxy.close);
      expect(await proxy.shadow(Request.fake(), maxBytes: 1024), isNull);
      await hung.firstClosed.timeout(const Duration(seconds: 10));
    });

    test(
      'an upstream stalling mid-body ends the response and closes',
      () async {
        final stalls = await upstream((socket) {
          socket.write(
            'HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n'
            '5\r\nhello\r\n',
          );
        });
        final proxy = UpstreamProxy(
          Uri.parse('http://127.0.0.1:${stalls.port}'),
          bodyIdleTimeout: const Duration(milliseconds: 200),
        );
        addTearDown(proxy.close);
        final response = await proxy.forward(Request.fake());
        final body = response.body as StreamBody;
        final received = <int>[];
        await expectLater(
          body.stream.forEach(received.addAll),
          throwsA(isA<TimeoutException>()),
        );
        expect(utf8.decode(received), 'hello');
        await stalls.firstClosed.timeout(const Duration(seconds: 10));
      },
    );

    test('headers named by Connection are not passed on', () async {
      late List<String> head;
      final echo = await upstream((socket) {
        socket.write(
          'HTTP/1.1 200 OK\r\nconnection: keep-alive, x-hop\r\n'
          'x-hop: 1\r\nx-end: 2\r\ncontent-length: 0\r\n\r\n',
        );
      });
      final proxy = UpstreamProxy(Uri.parse('http://127.0.0.1:${echo.port}'));
      addTearDown(proxy.close);
      final response = await proxy.forward(Request.fake());
      head = [for (final entry in response.headers.entries) entry.key];
      expect(head, contains('x-end'));
      expect(head, isNot(contains('x-hop')));
    });
  });
}
