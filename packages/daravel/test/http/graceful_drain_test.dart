import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/graceful_server_socket.dart';
import 'package:test/test.dart';

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
          api: (router) => router.get('/ping', (_) => 'pong'),
        )
        .create();

void main() {
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

    test('a keep-alive client sending all along gets every answer: told to '
        'close, it opens its next connection elsewhere', () async {
      final (_, engine) = await serving();
      final port = engine.port!;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final failures = <String>[];
      var answered = 0;
      var going = true;
      final load = () async {
        while (going) {
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/ping'),
            );
            final response = await request.close();
            await response.drain<void>();
            answered++;
          } on SocketException {
            // Refused once the server stopped accepting: the client would
            // go to another server; not a connection closed on a request.
            break;
          } on Object catch (error) {
            failures.add('$error');
          }
        }
      }();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.stop();
      going = false;
      await load;
      expect(failures, isEmpty, reason: 'answered $answered');
      expect(answered, greaterThan(0));
    });

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
}
