import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Sends [head] then [body] (raw) on a new socket to [port] and returns
/// the reply, read until the server closes or goes quiet.
Future<String> raw(int port, String head, [List<int> body = const []]) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final reply = BytesBuilder();
  final done = Completer<void>();
  socket
      .timeout(const Duration(seconds: 3), onTimeout: (sink) => sink.close())
      .listen(
        reply.add,
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object _) => done.isCompleted ? null : done.complete(),
        cancelOnError: true,
      );
  socket.write(head);
  try {
    socket.add(body);
    await socket.flush();
  } on SocketException {
    // Answered and closed first.
  }
  await done.future;
  socket.destroy();
  return utf8.decode(reply.takeBytes(), allowMalformed: true);
}

/// PX-1: the upstream proxy and its shadow runner, and CORS' `Vary`.
void main() {
  group('the upstream proxy', () {
    late Application app;
    late ServerEngine engine;

    Future<void> start(String upstream, Map<String, String> env) async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
          .withLogLevel(LogLevel.critical)
          .withRouting(api: (router) => router.get('/here', (_) => 'here'))
          .withUpstream(url: upstream, preserveHost: true)
          .create();
      await app.boot();
      engine = ServerEngine(
        app,
        ServeOptions.fromEnv(Env.fromMap(env), host: '127.0.0.1', port: 0),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
    }

    tearDown(() async {
      await engine.stop();
      await app.shutdown();
    });

    test('a client body refused half way (413) closes the upstream '
        'connection at once', () async {
      // An upstream that reads and never answers, counting its sockets.
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      var open = 0;
      upstream.listen((socket) {
        open++;
        socket.listen(
          (_) {},
          onDone: () {
            open--;
            socket.destroy();
          },
          onError: (Object _) => open--,
          cancelOnError: true,
        );
      });
      await start('http://127.0.0.1:${upstream.port}', {
        'HTTP_MAX_BODY': '${64 << 10}',
      });
      final body = Uint8List(256 << 10);
      final chunked = BytesBuilder();
      for (var at = 0; at < body.length; at += 16 << 10) {
        chunked
          ..add(utf8.encode('${(16 << 10).toRadixString(16)}\r\n'))
          ..add(Uint8List.sublistView(body, at, at + (16 << 10)))
          ..add(utf8.encode('\r\n'));
      }
      chunked.add(utf8.encode('0\r\n\r\n'));
      final reply = await raw(
        engine.port!,
        'POST /legacy/upload HTTP/1.1\r\nHost: localhost\r\n'
        'Content-Type: application/octet-stream\r\n'
        'Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
        chunked.takeBytes(),
      );
      expect(reply, startsWith('HTTP/1.1 413'));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (open > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(open, 0, reason: 'the upstream connection was aborted');
    });

    test('Connection: host keeps preserveHost; an x-forwarded-for it names '
        'is not passed on', () async {
      final seen = <String, String?>{};
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) async {
        seen['host'] = request.headers.value('host');
        seen['xff'] = request.headers.value('x-forwarded-for');
        request.response.write('ok');
        await request.response.close();
      });
      await start('http://127.0.0.1:${upstream.port}', const {});
      final reply = await raw(
        engine.port!,
        'GET /legacy/page HTTP/1.1\r\nHost: client.example\r\n'
        'Connection: host, x-forwarded-for, close\r\n'
        'X-Forwarded-For: 6.6.6.6\r\n\r\n',
      );
      expect(reply, startsWith('HTTP/1.1 200'));
      expect(seen['host'], 'client.example');
      expect(seen['xff'], '127.0.0.1', reason: 'this hop only');
    });
  });

  group('shadow except', () {
    final runner = ShadowParityRunner(
      UpstreamProxy(Uri.parse('http://127.0.0.1:9')),
      sampleRate: 1,
      except: const ['/secret', '/private/'],
      random: Random(1),
    );

    bool replayed(String path) {
      final request = Request.fake(path: path);
      runner.observe(request, Response.json(const {'a': 1}));
      return request.takeDeferred().isNotEmpty;
    }

    test('matched as the router matches, whole segments', () {
      for (final path in [
        '/secret',
        '//secret',
        '/secret/',
        '/secret/x',
        '//secret//x',
        '/private',
        '/private/y',
      ]) {
        expect(replayed(path), isFalse, reason: path);
      }
      for (final path in ['/secret_public', '/secrets', '/public', '/']) {
        expect(replayed(path), isTrue, reason: path);
      }
    });
  });

  group('CORS', () {
    late Application app;
    late ServerEngine engine;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withMiddleware(
            (m) => m.use([
              CorsMiddleware(
                const CorsConfig(allowedOrigins: ['https://app.test']),
              ),
            ]),
          )
          .withRouting(
            apiPrefix: '',
            api: (router) => router.get(
              '/data',
              (_) =>
                  Response.json(const {'a': 1})
                      .withHeader('vary', 'Accept-Encoding'),
            ),
          )
          .create();
      await app.boot();
      engine = ServerEngine(
        app,
        const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
    });

    tearDown(() async {
      await engine.stop();
      await app.shutdown();
    });

    String vary(String reply) => [
      for (final line in reply.split('\r\n'))
        if (line.toLowerCase().startsWith('vary:')) line.substring(5).trim(),
    ].join(', ');

    test(
      "Origin is added to the handler's Vary, not put in its place",
      () async {
        for (final origin in ['https://app.test', 'https://evil.test']) {
          final reply = await raw(
            engine.port!,
            'GET /data HTTP/1.1\r\nHost: localhost\r\nOrigin: $origin\r\n'
            'Connection: close\r\n\r\n',
          );
          expect(vary(reply), 'Accept-Encoding, Origin', reason: origin);
        }
        // A preflight has no handler's Vary.
        final preflight = await raw(
          engine.port!,
          'OPTIONS /data HTTP/1.1\r\nHost: localhost\r\n'
          'Origin: https://app.test\r\nAccess-Control-Request-Method: GET\r\n'
          'Connection: close\r\n\r\n',
        );
        expect(vary(preflight), 'Origin');
      },
    );
  });
}
