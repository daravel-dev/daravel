import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class _Store extends FormRequest {
  @override
  Map<String, Object> rules(Request request) => {'name': 'required'};
}

/// Since 1.28.0 the engine gives JSON and form bodies their own limit,
/// 1 MiB by default (`HTTP_MAX_JSON_BODY`, `HTTP_MAX_FORM_BODY`), the
/// limits `BodyLimitsMiddleware` already applied; other bodies keep
/// `HTTP_MAX_BODY` (50 MiB). A route's `bodyLimit` and the middleware
/// replace it. The same on a socket and from the test client.
void main() {
  Application app0({
    Map<String, String> env = const {},
    List<Middleware> global = const [],
  }) {
    return Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
        .withLogLevel(LogLevel.critical)
        .withMiddleware((m) => m.use(global))
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.post(
              '/echo',
              (request) async => {'length': (await request.bytes()).length},
            );
            router.post(
              '/input',
              (request) async => {'keys': (await request.all()).length},
            );
            router.post('/validated', (request) async {
              await request.validate({'name': 'required'});
              return {'ok': true};
            });
            router
                .post('/form-request', (_) => {'ok': true})
                .validates(_Store());
            router
                .post(
                  '/wide',
                  (request) async => {'length': (await request.bytes()).length},
                )
                .bodyLimit(4 << 20);
          },
        )
        .create();
  }

  String jsonOf(int bytes) {
    // {"name":"x","pad":"aaa…"} of exactly [bytes] bytes.
    const head = '{"name":"x","pad":"';
    const tail = '"}';
    return '$head${'a' * (bytes - head.length - tail.length)}$tail';
  }

  String formOf(int bytes) => 'name=x&pad=${'a' * (bytes - 11)}';

  const mib = 1 << 20;

  group('the test client', () {
    late TestClient client;
    late Application app;

    Future<void> start({
      Map<String, String> env = const {},
      List<Middleware> global = const [],
    }) async {
      app = app0(env: env, global: global);
      await app.boot();
      client = TestClient(app);
    }

    tearDown(() => app.shutdown());

    Future<TestResponse> post(String path, String body, String type) =>
        client.send('POST', path, body: body, headers: {'content-type': type});

    test('JSON and form: 1 MiB, the same 413 as the middleware', () async {
      await start();
      for (final (type, make) in [
        ('application/json', jsonOf),
        ('application/vnd.api+json', jsonOf),
        ('application/x-www-form-urlencoded', formOf),
      ]) {
        (await post('/echo', make(mib), type)).assertOk();
        final refused = await post('/echo', make(mib + 1), type);
        expect(refused.status, 413, reason: type);
        expect(refused.json, {
          'message': const PayloadTooLargeHttpException().message,
        }, reason: type);
      }
      // Any other type keeps HTTP_MAX_BODY (50 MiB).
      (await post('/echo', 'a' * (2 * mib), 'text/plain')).assertOk();
    });

    test('a 413 raised by reading the input is a 413, not a 500', () async {
      await start();
      for (final path in ['/input', '/validated', '/form-request']) {
        final response = await post(path, jsonOf(mib + 1), 'application/json');
        expect(response.status, 413, reason: path);
        expect(response.json, {
          'message': const PayloadTooLargeHttpException().message,
        }, reason: path);
      }
    });

    test('HTTP_MAX_JSON_BODY and HTTP_MAX_FORM_BODY; 0: only '
        'HTTP_MAX_BODY', () async {
      await start(
        env: {'HTTP_MAX_JSON_BODY': '${2 * mib}', 'HTTP_MAX_FORM_BODY': '0'},
      );
      (await post('/echo', jsonOf(2 * mib), 'application/json')).assertOk();
      expect(
        (await post('/echo', jsonOf(2 * mib + 1), 'application/json')).status,
        413,
      );
      final form = await post(
        '/echo',
        formOf(3 * mib),
        'application/x-www-form-urlencoded',
      );
      form.assertOk();
    });

    test('a negative value is an error at boot', () async {
      for (final name in ['HTTP_MAX_JSON_BODY', 'HTTP_MAX_FORM_BODY']) {
        final app = app0(env: {name: '-1'});
        await expectLater(app.boot(), throwsArgumentError, reason: name);
      }
      app = app0();
      await app.boot();
    });

    test('a route bodyLimit and the middleware replace it', () async {
      await start();
      (await post('/wide', jsonOf(3 * mib), 'application/json')).assertOk();
      await app.shutdown();
      await start(global: const [BodyLimitsMiddleware(json: 5 * mib)]);
      (await post('/echo', jsonOf(3 * mib), 'application/json')).assertOk();
      // The middleware's own, unchanged: its form default is 1 MiB.
      expect(
        (await post(
          '/echo',
          formOf(mib + 1),
          'application/x-www-form-urlencoded',
        )).status,
        413,
      );
    });
  });

  group('a socket', () {
    Future<ServerEngine> serve({Map<String, String> env = const {}}) async {
      final app = app0(env: env);
      await app.boot();
      addTearDown(app.shutdown);
      final engine = ServerEngine(
        app,
        ServeOptions.fromEnv(Env.fromMap(env), host: '127.0.0.1', port: 0),
        kernel: app.kernel,
        logger: Logger(minimumLevel: .critical),
      );
      await engine.start();
      addTearDown(engine.stop);
      return engine;
    }

    /// Sends [body] with [type], declared by `Content-Length` or sent
    /// `chunked`, and reads the reply until the server closes or goes quiet.
    Future<String> send(
      ServerEngine engine,
      String type,
      List<int> body, {
      required bool chunked,
    }) async {
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      final received = BytesBuilder();
      final closed = Completer<void>();
      void finish() {
        if (!closed.isCompleted) {
          closed.complete();
        }
      }

      socket
          .timeout(
            const Duration(seconds: 2),
            onTimeout: (sink) => sink.close(),
          )
          .listen(
            received.add,
            onError: (Object _) => finish(),
            onDone: finish,
            cancelOnError: true,
          );
      socket.write(
        'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: $type\r\n'
        '${chunked ? 'Transfer-Encoding: chunked' : 'Content-Length: ${body.length}'}'
        '\r\nConnection: close\r\n\r\n',
      );
      try {
        if (chunked) {
          const piece = 64 << 10;
          for (var at = 0; at < body.length; at += piece) {
            final end = at + piece < body.length ? at + piece : body.length;
            socket
              ..write('${(end - at).toRadixString(16)}\r\n')
              ..add(body.sublist(at, end))
              ..write('\r\n');
          }
          socket.write('0\r\n\r\n');
        } else {
          socket.add(body);
        }
        await socket.flush();
      } on SocketException {
        // Answered and closed before the whole body was sent.
      }
      await closed.future;
      socket.destroy();
      return utf8.decode(received.takeBytes(), allowMalformed: true);
    }

    for (final chunked in [false, true]) {
      final how = chunked ? 'chunked' : 'Content-Length';
      test('JSON and form above 1 MiB: 413 ($how)', () async {
        final engine = await serve();
        for (final (type, make) in [
          ('application/json', jsonOf),
          ('application/x-www-form-urlencoded', formOf),
        ]) {
          final over = await send(
            engine,
            type,
            utf8.encode(make(mib + 1)),
            chunked: chunked,
          );
          if (chunked) {
            // Refused while reading, never handled. The 413 itself does not
            // reach the client today: a chunked body over any limit
            // (HTTP_MAX_BODY, BodyLimitsMiddleware) closes the connection
            // without a response, on main before this change too; reported
            // separately.
            expect(over, isNot(startsWith('HTTP/1.1 200')), reason: type);
          } else {
            expect(over, startsWith('HTTP/1.1 413'), reason: '$type $how');
            expect(
              over,
              contains(const PayloadTooLargeHttpException().message),
            );
          }
          final under = await send(
            engine,
            type,
            utf8.encode(make(mib)),
            chunked: chunked,
          );
          expect(under, startsWith('HTTP/1.1 200'), reason: '$type $how');
        }
        // Another type: 2 MiB, under HTTP_MAX_BODY.
        final other = await send(
          engine,
          'application/octet-stream',
          List<int>.filled(2 * mib, 0x61),
          chunked: chunked,
        );
        expect(other, startsWith('HTTP/1.1 200'), reason: how);
      });
    }

    test('a smaller HTTP_MAX_BODY still applies to JSON', () async {
      final engine = await serve(env: {'HTTP_MAX_BODY': '${512 << 10}'});
      final over = await send(
        engine,
        'application/json',
        utf8.encode(jsonOf((512 << 10) + 1)),
        chunked: false,
      );
      expect(over, startsWith('HTTP/1.1 413'));
    });
  });
}
