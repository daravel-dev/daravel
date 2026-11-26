import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `BodyLimitsMiddleware` used to replace the limit a request arrived with
/// (`HTTP_MAX_BODY`) by its content-type limit, so a small `HTTP_MAX_BODY`
/// was raised to 1 MiB for JSON and forms and 50 MiB for the rest. As
/// global middleware it also refused a declared `Content-Length` before the
/// route was known, so a route's larger `.bodyLimit(n)` never applied.
///
/// Now the middleware only lowers the limit, and a route's `.bodyLimit(n)`
/// decides for its route.
const _refusal = '{\n    "message": "The POST data is too large."\n}';

const _kib64 = 64 << 10;
const _mib = 1 << 20;

final class _Tag implements Middleware {
  const _Tag(this.label, this.log);
  final String label;
  final List<String> log;

  @override
  Future<Response> handle(Request request, Next next) {
    log.add(label);
    return next(request);
  }
}

Future<Map<String, Object?>> _length(Request request) async =>
    <String, Object?>{'length': (await request.bytes()).length};

void _routes(Router router, List<String> log) {
  router.post('/echo', _length);
  router.post('/wide', _length).bodyLimit(4 * _mib);
  router.get('/only-get', (_) => 'got');
  router
      .post('/guarded', (_) {
        log.add('handler');
        return 'ok';
      })
      .middleware([_Tag('route', log)]);
  router.post('/ignore', (_) => 'ignored');
}

Future<Application> _app({
  List<Middleware> global = const <Middleware>[BodyLimitsMiddleware()],
  void Function(Router router)? routes,
  List<String>? log,
}) async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .withRouting(
        apiPrefix: '',
        api: routes ?? (router) => _routes(router, log ?? <String>[]),
      )
      .withMiddleware((m) => m.use(global))
      .create();
  await app.boot();
  addTearDown(app.shutdown);
  return app;
}

/// A POST of [size] bytes. [arrived] is the limit the request starts with
/// (what the engine sets from `HTTP_MAX_BODY`); [declare] false removes the
/// `Content-Length`, as a chunked body has none.
Request _post(
  String path,
  int size, {
  String type = 'application/json',
  int? arrived = Request.defaultMaxBodyBytes,
  bool declare = true,
  String method = 'POST',
}) {
  final request = Request.fake(
    method: method,
    path: path,
    body: 'x' * size,
    headers: {'content-type': type},
  );
  if (!declare) {
    request.headers.remove('content-length');
  }
  request.maxBodyBytes = arrived;
  return request;
}

Future<void> _expectRefused(Response response) async {
  expect(response.status, 413);
  expect(await response.bodyText(), _refusal);
  expect(response.headers.contentType, 'application/json');
}

Future<void> _expectLength(Response response, int length) async {
  expect(response.status, 200, reason: await response.bodyText());
  expect(jsonDecode(await response.bodyText()), {'length': length});
}

void main() {
  group('the middleware only lowers the limit a request arrived with', () {
    for (final type in const [
      'application/json',
      'text/plain',
      'application/x-www-form-urlencoded',
    ]) {
      test('64 KiB arrived, 150 000 bytes of $type: 413', () async {
        final app = await _app();
        await _expectRefused(
          await app.handle(_post('/echo', 150000, type: type, arrived: _kib64)),
        );
        // The same without a Content-Length: refused when read.
        await _expectRefused(
          await app.handle(
            _post('/echo', 150000, type: type, arrived: _kib64, declare: false),
          ),
        );
        await _expectLength(
          await app.handle(_post('/echo', _kib64, type: type, arrived: _kib64)),
          _kib64,
        );
      });
    }

    test('the arrived limit also holds below a larger type limit set '
        'on the middleware', () async {
      final app = await _app(
        global: const [BodyLimitsMiddleware(json: 8 * _mib, other: 8 * _mib)],
      );
      await _expectRefused(
        await app.handle(_post('/echo', 150000, arrived: _kib64)),
      );
      await _expectRefused(
        await app.handle(
          _post('/echo', 150000, type: 'text/plain', arrived: _kib64),
        ),
      );
    });

    test('no arrived limit: the type limit applies', () async {
      final app = await _app();
      await _expectRefused(
        await app.handle(_post('/echo', _mib + 1, arrived: null)),
      );
      await _expectRefused(
        await app.handle(
          _post('/echo', _mib + 1, arrived: null, declare: false),
        ),
      );
      await _expectLength(
        await app.handle(_post('/echo', _mib, arrived: null)),
        _mib,
      );
    });

    test('a type limit below the arrived limit still lowers it', () async {
      final app = await _app();
      // 50 MiB arrived (the default), JSON limit 1 MiB.
      await _expectRefused(await app.handle(_post('/echo', _mib + 1)));
      await _expectLength(await app.handle(_post('/echo', _mib)), _mib);
    });
  });

  group('a route bodyLimit decides under the global middleware', () {
    test('a declared JSON body above the type limit is served', () async {
      final app = await _app();
      await _expectLength(await app.handle(_post('/wide', 2 * _mib)), 2 * _mib);
    });

    test('a body above the route limit is refused', () async {
      final app = await _app();
      await _expectRefused(await app.handle(_post('/wide', 4 * _mib + 1)));
      await _expectRefused(
        await app.handle(_post('/wide', 4 * _mib + 1, declare: false)),
      );
      await _expectLength(await app.handle(_post('/wide', 4 * _mib)), 4 * _mib);
    });

    test('a route limit above the arrived limit raises it', () async {
      final app = await _app();
      await _expectLength(
        await app.handle(_post('/wide', 150000, arrived: _kib64)),
        150000,
      );
      await _expectLength(
        await app.handle(
          _post('/wide', 150000, arrived: _kib64, declare: false),
        ),
        150000,
      );
      await _expectRefused(
        await app.handle(_post('/wide', 4 * _mib + 1, arrived: _kib64)),
      );
    });

    test('a body without Content-Length is refused when read, and served '
        'under the raised route limit', () async {
      final app = await _app();
      await _expectRefused(
        await app.handle(_post('/echo', 2 * _mib, declare: false)),
      );
      await _expectLength(
        await app.handle(_post('/wide', 2 * _mib, declare: false)),
        2 * _mib,
      );
    });
  });

  group('a declared length over the limit is still refused early', () {
    test('no route matches: 413, not 404', () async {
      final app = await _app();
      await _expectRefused(await app.handle(_post('/nowhere', _mib + 1)));
      // Within the limit the 404 is answered as before.
      expect((await app.handle(_post('/nowhere', 16))).status, 404);
    });

    test('no route matches the method: 413, not 405 or the OPTIONS '
        'answer', () async {
      final app = await _app();
      await _expectRefused(await app.handle(_post('/only-get', _mib + 1)));
      await _expectRefused(
        await app.handle(_post('/only-get', _mib + 1, method: 'OPTIONS')),
      );
      expect((await app.handle(_post('/only-get', 16))).status, 405);
    });

    test('no route matches and unmatched is set: 413, unmatched is not '
        'called', () async {
      final app = await _app();
      var forwarded = 0;
      app.kernel.unmatched = (request) async {
        forwarded++;
        return Response.text('forwarded');
      };
      await _expectRefused(await app.handle(_post('/nowhere', _mib + 1)));
      expect(forwarded, 0);
      expect(
        await (await app.handle(_post('/nowhere', 16))).bodyText(),
        'forwarded',
      );
      expect(forwarded, 1);
    });

    test('a route without bodyLimit: 413 before the route middleware and '
        'the handler', () async {
      final log = <String>[];
      final app = await _app(log: log);
      await _expectRefused(await app.handle(_post('/guarded', _mib + 1)));
      expect(log, isEmpty);
      await _expectRefused(
        await app.handle(_post('/guarded', 150000, arrived: _kib64)),
      );
      expect(log, isEmpty);
      expect((await app.handle(_post('/guarded', 16))).status, 200);
      expect(log, ['route', 'handler']);
    });

    test('the global middleware after it still runs before the '
        'refusal', () async {
      // The refusal waits for the route, so later global middleware sees
      // the request; nothing of the route runs.
      final log = <String>[];
      final app = await _app(
        global: [const BodyLimitsMiddleware(), _Tag('global', log)],
        log: log,
      );
      await _expectRefused(await app.handle(_post('/guarded', _mib + 1)));
      expect(log, ['global']);
    });
  });

  group('as route middleware', () {
    Future<Application> routed(List<String> log) => _app(
      global: const [],
      routes: (router) {
        router.post('/routed', _length).bodyLimit(10).middleware([
          const BodyLimitsMiddleware(),
        ]);
        router
            .post('/typed', (request) {
              log.add('handler');
              return _length(request);
            })
            .middleware([const BodyLimitsMiddleware()]);
      },
    );

    test('the route limit is used as it is', () async {
      final app = await routed(<String>[]);
      await _expectRefused(
        await app.handle(_post('/routed', 20, type: 'text/plain')),
      );
      await _expectLength(
        await app.handle(_post('/routed', 10, type: 'text/plain')),
        10,
      );
      // Also above the limit the request arrived with.
      await _expectLength(
        await app.handle(_post('/routed', 8, type: 'text/plain', arrived: 4)),
        8,
      );
    });

    test('without a route limit it lowers the arrived limit and refuses at '
        'once', () async {
      final log = <String>[];
      final app = await routed(log);
      await _expectRefused(
        await app.handle(_post('/typed', 150000, arrived: _kib64)),
      );
      await _expectRefused(await app.handle(_post('/typed', _mib + 1)));
      expect(log, isEmpty);
      await _expectLength(await app.handle(_post('/typed', _mib)), _mib);
      expect(log, ['handler']);
    });
  });

  group('without the middleware nothing changes', () {
    test('a declared length over the limit reaches a handler that never '
        'reads the body', () async {
      final app = await _app(global: const []);
      final request = Request.fake(
        method: 'POST',
        path: '/ignore',
        body: 'x',
        headers: {'content-length': '${60 * _mib}'},
      );
      final response = await app.handle(request);
      expect(response.status, 200);
      expect(await response.bodyText(), 'ignored');
      // No route: the 404 as before.
      final missing = Request.fake(
        method: 'POST',
        path: '/nowhere',
        body: 'x',
        headers: {'content-length': '${60 * _mib}'},
      );
      expect((await app.handle(missing)).status, 404);
    });

    test('a handler that reads is refused by the arrived limit', () async {
      final app = await _app(global: const []);
      await _expectRefused(
        await app.handle(_post('/echo', 150000, arrived: _kib64)),
      );
      await _expectLength(await app.handle(_post('/echo', 2 * _mib)), 2 * _mib);
      await _expectLength(
        await app.handle(_post('/wide', 150000, arrived: _kib64)),
        150000,
      );
    });
  });

  test('the 413 answer is the one the middleware always gave', () async {
    final before = laravelErrorResponse(<String, Object?>{
      'message': const PayloadTooLargeHttpException().message,
    }, status: 413);
    final expected = await before.bodyText();
    expect(expected, _refusal);
    final app = await _app();
    for (final request in [
      _post('/nowhere', _mib + 1),
      _post('/echo', _mib + 1),
      _post('/guarded', _mib + 1),
      _post('/wide', 4 * _mib + 1),
    ]) {
      final response = await app.handle(request);
      expect(response.status, before.status);
      expect(await response.bodyText(), expected);
      expect(
        response.headers.toSingleValueMap(),
        before.headers.toSingleValueMap(),
      );
    }
    // APP_DEBUG adds nothing to it.
    final debug = await _app();
    debug.kernel.exceptions.debug = true;
    for (final request in [
      _post('/nowhere', _mib + 1),
      _post('/echo', _mib + 1),
      _post('/wide', 4 * _mib + 1),
      _post('/echo', 2 * _mib, declare: false),
    ]) {
      await _expectRefused(await debug.handle(request));
    }
  });

  group('on a socket, HTTP_MAX_BODY of 64 KiB', () {
    Future<ServerEngine> serve() async {
      final app = await _app();
      final engine = ServerEngine(
        app,
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          maxBodyBytes: _kib64,
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: .critical),
      );
      await engine.start();
      addTearDown(engine.stop);
      return engine;
    }

    /// Sends [size] bytes as JSON, declared or chunked, and reads the reply
    /// until the server closes or goes quiet for a second. A server that
    /// refuses a declared body answers without reading it, so the write may
    /// fail.
    Future<String> send(
      ServerEngine engine,
      String path,
      int size, {
      bool chunked = false,
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
            const Duration(seconds: 1),
            onTimeout: (sink) => sink.close(),
          )
          .listen(
            received.add,
            onError: (Object _) => finish(),
            onDone: finish,
            cancelOnError: true,
          );
      socket.write(
        'POST $path HTTP/1.1\r\nHost: localhost\r\n'
        'Content-Type: application/json\r\n'
        '${chunked ? 'Transfer-Encoding: chunked' : 'Content-Length: $size'}'
        '\r\nConnection: close\r\n\r\n',
      );
      if (chunked) {
        socket.write('${size.toRadixString(16)}\r\n');
      }
      socket.add(List<int>.filled(size, 0x61));
      if (chunked) {
        socket.write('\r\n0\r\n\r\n');
      }
      try {
        await socket.flush();
      } on SocketException {
        // Answered and closed before the whole body was sent.
      }
      await closed.future;
      socket.destroy();
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (engine.inFlight != 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.inFlight, 0, reason: 'the slot is released');
      return utf8.decode(received.takeBytes(), allowMalformed: true);
    }

    test('a declared JSON body of 150 000 bytes is refused', () async {
      final engine = await serve();
      final reply = await send(engine, '/echo', 150000);
      expect(reply, startsWith('HTTP/1.1 413'));
      expect(reply, endsWith(_refusal));
      expect(
        await send(engine, '/echo', _kib64),
        contains('{"length":$_kib64}'),
      );
    });

    test('a chunked JSON body of 150 000 bytes is not served', () async {
      final engine = await serve();
      final reply = await send(engine, '/echo', 150000, chunked: true);
      // The read stops at the limit and the server answers 413. It then
      // closes a connection that still holds unread body, which can cost
      // the client the answer (a reset): the handler never has the body.
      expect(reply, anyOf(isEmpty, startsWith('HTTP/1.1 413')));
      expect(reply, isNot(contains('"length"')));
      expect(
        await send(engine, '/echo', _kib64, chunked: true),
        contains('{"length":$_kib64}'),
      );
    });

    test('the route bodyLimit serves it, declared or chunked', () async {
      final engine = await serve();
      expect(
        await send(engine, '/wide', 150000),
        contains('{"length":150000}'),
      );
      expect(
        await send(engine, '/wide', 150000, chunked: true),
        contains('{"length":150000}'),
      );
    });
  });
}
