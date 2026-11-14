import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

// dart:io's HttpException is the one the client throws; the framework's
// (an HTTP error response) would shadow it.
import 'package:daravel/daravel.dart' hide HttpException;
import 'package:daravel/src/http/graceful_server_socket.dart';
import 'package:test/test.dart';

import 'support/websocket_counts.dart';

/// Opens a connection, waits for [send], then sends one request and
/// returns the whole response, or `closed` / the error.
Future<String> requestWhen(
  int port,
  Future<void> send, {
  String path = '/',
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  try {
    await send;
    socket.write('GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n');
    await socket.flush();
    final response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 10));
    return response.isEmpty ? 'closed' : response;
  } on Object catch (error) {
    return 'error: $error';
  } finally {
    socket.destroy();
  }
}

/// Waits until [done] (a connection reaches the isolate a moment after
/// the client's connect returns, longer on a loaded machine).
Future<void> until(FutureOr<bool> Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// What a keep-alive client's failed request means for the drain.
enum DrainOutcome {
  /// A new connection the server no longer took: allowed, the client goes
  /// to another server.
  refusedNew,

  /// A request sent on a connection the server closed under it: what the
  /// drain must never do.
  closedOnRequest,

  /// A response that started and did not end.
  cutShort,
}

/// Classifies [error], thrown while [connecting] (in `getUrl`, before the
/// request is written) or later (sending it, reading the response).
///
/// A raw [OSError] counts as refused only while connecting: `HttpClient`
/// sets `tcpNoDelay` on a new socket inside `getUrl`, and on a socket the
/// server reset that throws an [OSError], not a [SocketException] (seen on
/// macOS). Later, an [OSError] means a request was lost, so it is not
/// excused. Anything else is not a drain outcome: `null`, rethrow it.
DrainOutcome? classifyDrainError(Object error, {required bool connecting}) =>
    switch (error) {
      SocketException() => DrainOutcome.refusedNew,
      OSError() when connecting => DrainOutcome.refusedNew,
      OSError() => DrainOutcome.cutShort,
      HttpException(:final message)
          when message.contains('before full header') =>
        DrainOutcome.closedOnRequest,
      HttpException() => DrainOutcome.cutShort,
      _ => null,
    };

/// The other isolate of a shared port: answers `other`, and its accepted
/// count to each message on the port it sends first.
Future<void> otherIsolate(List<Object> args) async {
  final socket = await GracefulServerSocket.bind(
    InternetAddress.loopbackIPv4,
    args[0] as int,
    shared: true,
  );
  HttpServer.listenOn(socket).listen(
    (r) => r.response
      ..write('other')
      ..close(),
  );
  final control = ReceivePort();
  control.listen((Object? reply) => (reply! as SendPort).send(socket.accepted));
  (args[1] as SendPort).send(control.sendPort);
}

Application drainApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) => router
            ..get('/ping', (_) => 'pong')
            ..ws('/ws', (socket, _) => socket.add('hello'))
            // Its headers go out at once, its body over half a second.
            ..get(
              '/stream',
              (_) => Response.stream(
                Stream<List<int>>.periodic(
                  const Duration(milliseconds: 50),
                  (i) => utf8.encode('chunk $i\n'),
                ).take(10),
                contentType: 'text/plain',
              ),
            ),
        )
        .create();

void main() {
  // First, so it runs last: after every tear-down of the tests.
  tearDown(expectWebSocketCountsReleased);

  group('dart:io: what the drain relies on (each OS in CI)', () {
    test('HttpServer.close closes a connection accepted before it whose '
        'request had not arrived (why the engine needs the wrapper)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(
        (r) => r.response
          ..write('ok')
          ..close(),
      );
      final send = Completer<void>();
      final answer = requestWhen(server.port, send.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final closing = server.close();
      send.complete();
      expect(await answer, isNot(contains('200 OK')));
      await closing;
    });

    test('with GracefulServerSocket a connection accepted before '
        'stopAccepting is answered, a new one refused', () async {
      final socket = await GracefulServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final server = HttpServer.listenOn(socket);
      server.listen(
        (r) => r.response
          ..write('ok')
          ..close(),
      );
      final send = Completer<void>();
      final answer = requestWhen(socket.port, send.future);
      await until(() => socket.accepted == 1, 'the connection accepted');
      await socket.stopAccepting();
      await socket.stopAccepting(); // idempotent
      expect(socket.accepting, isFalse);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, socket.port),
        throwsA(isA<SocketException>()),
      );
      send.complete();
      expect(await answer, contains('200 OK'));
      await socket.finish();
      await socket.finish(); // idempotent
      await server.close().timeout(const Duration(seconds: 5));
    });

    test('shared port, two isolates: all connections accepted before one '
        'stops accepting are answered; new ones go to the other', () async {
      final socket = await GracefulServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: true,
      );
      final server = HttpServer.listenOn(socket);
      server.listen(
        (r) => r.response
          ..write('main')
          ..close(),
      );
      final ready = ReceivePort();
      final isolate = await Isolate.spawn(otherIsolate, [
        socket.port,
        ready.sendPort,
      ]);
      addTearDown(() => isolate.kill(priority: Isolate.immediate));
      final other = await ready.first as SendPort;
      Future<int> otherAccepted() async {
        final reply = ReceivePort();
        other.send(reply.sendPort);
        final count = await reply.first as int;
        reply.close();
        return count;
      }

      final send = Completer<void>();
      final before = [
        for (var i = 0; i < 20; i++) requestWhen(socket.port, send.future),
      ];
      await until(
        () async => socket.accepted + await otherAccepted() == 20,
        'the 20 connections accepted',
      );
      await socket.stopAccepting();
      final after = [
        for (var i = 0; i < 10; i++)
          await requestWhen(socket.port, Future<void>.value()),
      ];
      send.complete();
      final answers = await Future.wait(before);
      expect(answers.where((a) => !a.contains('200 OK')), isEmpty);
      expect(after.where((a) => !a.contains('200 OK')), isEmpty);
      expect(after.where((a) => a.contains('main')), isEmpty);
      await socket.finish();
      await server.close();
    });

    test('a bind that fails leaks nothing', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      await expectLater(
        GracefulServerSocket.bind(InternetAddress.loopbackIPv4, taken.port),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('ServerEngine.stop', () {
    Future<(Application, ServerEngine)> serving({
      Duration drainGrace = const Duration(milliseconds: 250),
    }) async {
      final app = drainApp();
      await app.boot();
      addTearDown(app.shutdown);
      final engine = ServerEngine(
        app,
        ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          shutdownTimeout: const Duration(seconds: 5),
          drainGrace: drainGrace,
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
      return (app, engine);
    }

    test('connections accepted before the drain are answered, with '
        'Connection: close, and stop ends within its timeout', () async {
      final (_, engine) = await serving();
      final port = engine.port!;
      final send = Completer<void>();
      final pending = [
        for (var i = 0; i < 20; i++)
          requestWhen(port, send.future, path: '/ping'),
      ];
      await until(
        () => engine.acceptedConnections == 20,
        'the 20 connections accepted',
      );
      final watch = Stopwatch()..start();
      final stopping = engine.stop();
      send.complete();
      final answers = await Future.wait(pending);
      await stopping;
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(answers.where((a) => !a.contains('200 OK')), isEmpty);
      expect(
        answers.every((a) => a.toLowerCase().contains('connection: close')),
        isTrue,
      );
    });

    test('a WebSocket handshake read during the drain is upgraded and told '
        'to go away, not refused with 426', () async {
      final (_, engine) = await serving();
      final port = engine.port!;
      final send = Completer<void>();
      Future<String> handshake() async {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        try {
          await send.future;
          socket.write(
            'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
            'Sec-WebSocket-Version: 13\r\n\r\n',
          );
          await socket.flush();
          // Everything until the server closes: the 101, the frame it sent
          // and its close frame (goingAway, 1001).
          final bytes = await socket
              .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
              .timeout(const Duration(seconds: 10));
          return latin1.decode(bytes);
        } on Object catch (error) {
          return 'error: $error';
        } finally {
          socket.destroy();
        }
      }

      final pending = [for (var i = 0; i < 5; i++) handshake()];
      await until(
        () => engine.acceptedConnections == 5,
        'the 5 connections accepted',
      );
      final stopping = engine.stop();
      send.complete();
      final answers = await Future.wait(pending);
      await stopping;
      for (final answer in answers) {
        expect(answer, startsWith('HTTP/1.1 101'), reason: answer);
        expect(answer, isNot(contains('426')));
        final frames = answer.substring(answer.indexOf('\r\n\r\n') + 4);
        expect(
          answer,
          contains('hello'),
          reason: 'after the headers: ${frames.codeUnits}',
        );
        // The close frame's status code, 1001 (goingAway), big-endian.
        expect(answer, contains(String.fromCharCodes(const [0x03, 0xE9])));
      }
    });

    test('a keep-alive client sending all along gets every answer: told to '
        'close, it opens its next connection elsewhere', () async {
      final (_, engine) = await serving();
      final port = engine.port!;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      // Three outcomes, counted apart: a request sent on a connection the
      // server closed under it (what the drain must never do), a response
      // cut short, and a new connection refused once the server stopped
      // accepting (allowed: the client goes to another server).
      final closedOnRequest = <String>[];
      final cutShort = <String>[];
      var refusedNew = 0;
      var answered = 0;
      var going = true;
      final load = () async {
        while (going) {
          var connecting = true;
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/ping'),
            );
            connecting = false;
            final response = await request.close();
            final body = await utf8.decodeStream(response);
            if (body != 'pong') {
              cutShort.add(body);
            }
            answered++;
          } on Object catch (error) {
            switch (classifyDrainError(error, connecting: connecting)) {
              case DrainOutcome.refusedNew:
                refusedNew++;
                return;
              case DrainOutcome.closedOnRequest:
                closedOnRequest.add('$error');
              case DrainOutcome.cutShort:
                cutShort.add('$error');
              case null:
                rethrow;
            }
          }
        }
      }();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.stop();
      going = false;
      await load;
      expect(closedOnRequest, isEmpty, reason: 'answered $answered');
      expect(cutShort, isEmpty, reason: 'answered $answered');
      expect(refusedNew, lessThanOrEqualTo(1));
      expect(answered, greaterThan(0));
    });

    test('a streamed response under way when the drain begins ends whole, '
        'its headers already sent left alone', () async {
      final (_, engine) = await serving();
      final port = engine.port!;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/stream'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      final body = utf8.decodeStream(response);
      // Headers out, the body still coming: now the drain.
      final stopping = engine.stop();
      expect(await body, [for (var i = 0; i < 10; i++) 'chunk $i\n'].join());
      await stopping;
    });

    for (final force in [false, true]) {
      test('after stop(force: $force) the port is free at once', () async {
        final (_, engine) = await serving();
        final port = engine.port!;
        await engine.stop(force: force);
        // Bound again, not shared: it fails while the engine's socket is
        // still bound (and accepting connections nobody serves).
        final again = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await again.close();
      });
    }

    test(
      'drainGrace zero: the drain as before, still within the timeout',
      () async {
        final (_, engine) = await serving(drainGrace: Duration.zero);
        final watch = Stopwatch()..start();
        await engine.stop();
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );
  });

  group('classifyDrainError', () {
    const reset = OSError('Connection reset by peer', 54);

    test('a raw OSError while connecting is a refused new connection '
        '(tcpNoDelay on a socket the server reset)', () {
      expect(
        classifyDrainError(reset, connecting: true),
        DrainOutcome.refusedNew,
      );
    });

    test('a raw OSError after the request was written is not excused', () {
      expect(
        classifyDrainError(reset, connecting: false),
        DrainOutcome.cutShort,
      );
    });

    test('SocketException and HttpException keep their meaning', () {
      expect(
        classifyDrainError(
          const SocketException('Connection refused'),
          connecting: true,
        ),
        DrainOutcome.refusedNew,
      );
      expect(
        classifyDrainError(
          const HttpException(
            'Connection closed before full header was '
            'received',
          ),
          connecting: false,
        ),
        DrainOutcome.closedOnRequest,
      );
      expect(
        classifyDrainError(
          const HttpException('Connection closed while receiving data'),
          connecting: false,
        ),
        DrainOutcome.cutShort,
      );
    });

    test('anything else is not a drain outcome', () {
      expect(classifyDrainError(StateError('x'), connecting: true), isNull);
    });
  });
}
