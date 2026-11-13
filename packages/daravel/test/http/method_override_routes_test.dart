import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Reads the body before routing, as the global middleware may.
final class _EarlyReader implements Middleware {
  const _EarlyReader();

  @override
  Future<Response> handle(Request request, Next next) async {
    if (request.path.startsWith('/early')) {
      await request.body();
    }
    return next(request);
  }
}

/// `MethodOverrideMiddleware` before routing: a form's body is read only
/// where a `_method` can change the route (a PUT, PATCH or DELETE route on
/// its path), under the loosest limit and timeout of the routes it may
/// reach; the matched route's own limit is checked against what was read.
void main() {
  const kib = 1 << 10;
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('m1_'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// Files the multipart parser left under this test's temporary
  /// directory (the requests run with it as `Directory.systemTemp`).
  int leftFiles() {
    final uploads = Directory('${temp.path}/daravel-uploads');
    return uploads.existsSync()
        ? uploads.listSync(recursive: true).whereType<File>().length
        : 0;
  }

  Future<T> inTemp<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(body, getSystemTempDirectory: () => temp);

  Application build() =>
      Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withMiddleware((m) => m.use(const [_EarlyReader()]))
          .withRouting(
            apiPrefix: '',
            api: (r) {
              // Reads the parsed input, as a handler does (`all()`,
              // `validate`): it does not go back to the bytes.
              Future<Object?> read(Request request) async {
                await request.all();
                return {
                  'method': request.method,
                  'read': request.bodyBytesRead,
                };
              }

              // A POST and a PUT route on one path, each with its limit.
              r.post('/both', read).bodyLimit(256 * kib);
              r.put('/both', read).bodyLimit(128 * kib);
              // Only a POST route.
              r.post('/post-only', read);
              // A POST route that takes large uploads, beside a PUT route
              // with no limit of its own.
              r.post('/upload', read).bodyLimit(4 << 20);
              r.put('/upload', read);
              // A PUT route that must answer within a second.
              r.put('/slow', read).timeout(const Duration(seconds: 1));
              // Read before routing by another global middleware.
              r.post('/early', read).bodyLimit(64 * kib);
              // Which method arrived, and whether the body was read yet.
              Object? arrived(Request request) => {
                'method': request.method,
                'readBefore': request.bodyBytesRead,
              };
              r.post('/header', arrived);
              r.put('/header', arrived);
              // BodyLimitsMiddleware on a group: after routing.
              r.group(
                (g) => g.put('/grouped', read),
                middleware: const [BodyLimitsMiddleware(form: 256 * kib)],
              );
            },
          )
          .create();

  String form(int bytes, {String? method}) {
    final prefix = method == null ? 'pad=' : '_method=$method&pad=';
    return '$prefix${'a' * (bytes - prefix.length)}';
  }

  group('the test client', () {
    late Application app;
    late TestClient client;

    setUp(() async {
      app = build();
      await app.boot();
      client = TestClient(app);
    });
    tearDown(() => app.shutdown());

    Future<TestResponse> post(
      String path,
      String body, {
      Map<String, String> headers = const {},
    }) => client.send(
      'POST',
      path,
      body: body,
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        ...headers,
      },
    );

    test("a body read before routing still meets the route's limit", () async {
      // Read for its `_method` (a PUT route exists): 300 KiB is within the
      // loosest limit there (POST's 256 KiB? no: the form default, 1 MiB),
      // and over the POST route's own.
      expect((await post('/both', form(300 * kib))).status, 413);
      expect((await post('/both', form(200 * kib))).json, {
        'method': 'POST',
        'read': 200 * kib,
      });
      // Overridden to PUT, whose limit is 128 KiB.
      expect((await post('/both', form(200 * kib, method: 'PUT'))).status, 413);
      expect((await post('/both', form(100 * kib, method: 'PUT'))).json, {
        'method': 'PUT',
        'read': 100 * kib,
      });
      // Read early by another middleware: the same check.
      expect((await post('/early', form(100 * kib))).status, 413);
    });

    test('the loosest limit of the routes it may reach: a large POST '
        'upload beside a PUT route is not refused', () async {
      final big = form(3 << 20);
      expect((await post('/upload', big)).json, {
        'method': 'POST',
        'read': 3 << 20,
      });
      // To PUT, which has the form default (1 MiB): refused.
      expect((await post('/upload', form(3 << 20, method: 'PUT'))).status, 413);
    });

    test('no PUT/PATCH/DELETE route: the body stays unread; a _method in '
        'the query still applies', () async {
      // In the body: stays POST (Laravel: 405). In the query: 405, as
      // Laravel.
      expect((await post('/post-only', form(64, method: 'PUT'))).json, {
        'method': 'POST',
        'read': 64,
      });
      expect((await post('/post-only?_method=PUT', form(10))).status, 405);
    });

    test('the header overrides without reading the body; GET, HEAD, '
        'CONNECT, TRACE and other values are ignored', () async {
      expect(
        (await post(
          '/header',
          form(10),
          headers: {'x-http-method-override': 'put'},
        )).json,
        {'method': 'PUT', 'readBefore': 0},
      );
      for (final value in ['GET', 'HEAD', 'CONNECT', 'TRACE', 'P-T']) {
        expect(
          (await post(
            '/header',
            form(10),
            headers: {'x-http-method-override': value},
          )).jsonMap['method'],
          'POST',
          reason: value,
        );
      }
      // A body `_method` is read here (a PUT route exists).
      expect((await post('/header', form(64, method: 'PUT'))).json, {
        'method': 'PUT',
        'readBefore': 64,
      });
    });
  });

  group('a socket', () {
    late Application app;
    late ServerEngine engine;

    Future<void> start() async {
      app = build();
      await app.boot();
      engine = ServerEngine(
        app,
        const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
    }

    tearDown(() async {
      await engine.stop();
      await app.shutdown();
    });

    /// Sends a multipart body of [fileBytes] to [path], at [chunkDelay]
    /// per 16 KiB when given, and returns the status line (or '' when the
    /// connection closed without one). [dropAfter] closes the socket after
    /// that many bytes of the file.
    Future<String> upload(
      String path,
      int fileBytes, {
      String? method,
      Duration? chunkDelay,
      int? dropAfter,
    }) async {
      const boundary = 'm1-boundary';
      final head = utf8.encode(
        '${method == null ? '' : '--$boundary\r\nContent-Disposition: '
                  'form-data; name="_method"\r\n\r\n$method\r\n'}'
        '--$boundary\r\nContent-Disposition: form-data; name="doc"; '
        'filename="a.bin"\r\nContent-Type: application/octet-stream\r\n\r\n',
      );
      final tail = utf8.encode('\r\n--$boundary--\r\n');
      final total = head.length + fileBytes + tail.length;
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      final reply = BytesBuilder();
      final done = Completer<void>();
      socket.listen(
        reply.add,
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object _) => done.isCompleted ? null : done.complete(),
        cancelOnError: true,
      );
      socket
        ..write(
          'POST $path HTTP/1.1\r\nHost: localhost\r\n'
          'Accept: application/json\r\nConnection: close\r\n'
          'Content-Type: multipart/form-data; boundary=$boundary\r\n'
          'Content-Length: $total\r\n\r\n',
        )
        ..add(head);
      try {
        var sent = 0;
        while (sent < fileBytes && !done.isCompleted) {
          if (dropAfter != null && sent >= dropAfter) {
            socket.destroy();
            return '';
          }
          final n = fileBytes - sent < 16 * kib ? fileBytes - sent : 16 * kib;
          socket.add(Uint8List(n));
          await Future.any([socket.flush(), done.future]);
          sent += n;
          if (chunkDelay != null) {
            await Future<void>.delayed(chunkDelay);
          }
        }
        if (!done.isCompleted) {
          socket.add(tail);
          await Future.any([socket.flush(), done.future]);
        }
      } on SocketException {
        // Answered and closed early.
      }
      await done.future.timeout(const Duration(seconds: 15));
      socket.destroy();
      final text = utf8.decode(reply.takeBytes(), allowMalformed: true);
      return text.split('\r\n').first;
    }

    Future<void> settled() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((engine.inFlight != 0 || leftFiles() != 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('BodyLimitsMiddleware on a route group checks what was read '
        'before routing: a chunked form, which declares no length', () async {
      await start();
      final body = utf8.encode(form(300 * kib, method: 'PUT'));
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      final reply = BytesBuilder();
      final done = Completer<void>();
      socket.listen(
        reply.add,
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object _) => done.isCompleted ? null : done.complete(),
        cancelOnError: true,
      );
      socket.write(
        'POST /grouped HTTP/1.1\r\nHost: localhost\r\n'
        'Accept: application/json\r\nConnection: close\r\n'
        'Content-Type: application/x-www-form-urlencoded\r\n'
        'Transfer-Encoding: chunked\r\n\r\n',
      );
      for (var at = 0; at < body.length; at += 16 * kib) {
        final end = at + 16 * kib < body.length ? at + 16 * kib : body.length;
        socket
          ..write('${(end - at).toRadixString(16)}\r\n')
          ..add(body.sublist(at, end))
          ..write('\r\n');
      }
      socket.write('0\r\n\r\n');
      await socket.flush();
      await done.future.timeout(const Duration(seconds: 15));
      socket.destroy();
      final status = utf8.decode(reply.takeBytes()).split('\r\n').first;
      expect(status, startsWith('HTTP/1.1 413'));
    });

    test(
      'a 2 MiB multipart POST where no route takes it: 404, nothing '
      'written',
      () => inTemp(() async {
        await start();
        expect(await upload('/nowhere', 2 << 20), startsWith('HTTP/1.1 404'));
        await settled();
        expect(leftFiles(), 0);
        // Never parsed: the parser did not even make its directory.
        expect(Directory('${temp.path}/daravel-uploads').existsSync(), isFalse);
      }),
    );

    test(
      'parsed for its _method: over the limit, too slow, or dropped, '
      'the temporary files go',
      () => inTemp(() async {
        await start();
        // Over the loosest limit of /both (256 KiB): refused while parsing.
        expect(
          await upload('/both', 512 * kib, method: 'PUT'),
          startsWith('HTTP/1.1 413'),
        );
        await settled();
        expect(leftFiles(), 0, reason: '413');
        // Slower than the PUT route's second: 503 before routing.
        final watch = Stopwatch()..start();
        expect(
          await upload(
            '/slow',
            256 * kib,
            method: 'PUT',
            chunkDelay: const Duration(milliseconds: 200),
          ),
          startsWith('HTTP/1.1 503'),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        await settled();
        expect(leftFiles(), 0, reason: '503');
        // The client goes away in the middle.
        await upload('/both', 200 * kib, method: 'PUT', dropAfter: 64 * kib);
        await settled();
        expect(leftFiles(), 0, reason: 'dropped');
        expect(engine.inFlight, 0);
      }),
    );
  });
}
