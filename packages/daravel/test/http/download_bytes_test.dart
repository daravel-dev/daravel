import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Response.downloadBytes` and `Response.streamDownload` (#323): a
/// download of content made for the request, the type from the name, the
/// disposition as `contentDisposition` writes it.
void main() {
  group('downloadBytes', () {
    test('the type comes from the name, then octet-stream', () {
      final csv = Response.downloadBytes(utf8.encode('a,b\n'), name: 'r.csv');
      expect(csv.headers.first('content-type'), startsWith('text/csv'));
      expect(
        csv.headers.first('content-disposition'),
        'attachment; filename="r.csv"',
      );
      final unknown = Response.downloadBytes([1, 2], name: 'exam.seb');
      expect(unknown.headers.first('content-type'), 'application/octet-stream');
    });

    test('an explicit type and headers win; a non-ASCII name is carried', () {
      final response = Response.downloadBytes(
        [1],
        name: 'ujian é.seb',
        contentType: 'application/seb',
        headers: {'cache-control': 'no-store'},
      );
      expect(response.headers.first('content-type'), 'application/seb');
      expect(response.headers.first('cache-control'), 'no-store');
      expect(
        response.headers.first('content-disposition'),
        contains("filename*=UTF-8''ujian%20%C3%A9.seb"),
      );
      expect(response.status, 200);
    });

    test('a name with a path is refused, as contentDisposition does', () {
      expect(
        () => Response.downloadBytes([1], name: '../etc/passwd'),
        throwsArgumentError,
      );
    });
  });

  group('streamDownload over a socket', () {
    late Application app;
    late ServerEngine engine;
    late HttpClient client;
    late Completer<void> stopped;
    late bool started;

    setUp(() async {
      stopped = Completer<void>();
      started = false;
      // Rows produced as the client reads, never all at once.
      Stream<List<int>> rows(int count, {Duration pause = Duration.zero}) =>
          () async* {
            started = true;
            try {
              for (var i = 0; i < count; i++) {
                yield utf8.encode('row $i\n');
                await Future<void>.delayed(pause);
              }
            } finally {
              if (!stopped.isCompleted) {
                stopped.complete();
              }
            }
          }();
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (r) {
              r.get(
                '/export',
                (_) => Response.streamDownload(rows(3), name: 'rows.csv'),
              );
              r.get(
                '/endless',
                (_) => Response.streamDownload(
                  rows(1 << 30, pause: const Duration(milliseconds: 5)),
                  name: 'endless.csv',
                ),
              );
            },
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
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await engine.stop();
      await app.shutdown();
    });

    Future<HttpClientResponse> send(String method, String path) async =>
        (await client.open(method, '127.0.0.1', engine.port!, path)).close();

    test('the rows arrive as an attachment, typed from the name', () async {
      final response = await send('GET', '/export');
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/csv');
      expect(
        response.headers.value('content-disposition'),
        'attachment; filename="rows.csv"',
      );
      expect(
        await response.transform(utf8.decoder).join(),
        'row 0\nrow 1\nrow 2\n',
      );
    });

    test('HEAD gets the headers and never starts the producer', () async {
      final response = await send('HEAD', '/export');
      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-disposition'),
        'attachment; filename="rows.csv"',
      );
      await response.drain<void>();
      expect(started, isFalse);
    });

    test('a client that goes away stops the producer', () async {
      final response = await send('GET', '/endless');
      // Read a little, then go away.
      await response.first;
      client.close(force: true);
      await stopped.future.timeout(const Duration(seconds: 10));
      expect(stopped.isCompleted, isTrue);
    });
  });
}
