import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('uploads stream from a real socket to temporary files', () async {
    final base = Directory.systemTemp.createTempSync('daravel_socket_upload');
    addTearDown(() => base.deleteSync(recursive: true));
    final app = Application.configure(basePath: base.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          api: (r) => r
              .post('/upload', (req) async {
                final file = (await req.file('doc'))!;
                return {
                  'title': (await req.all())['title'],
                  'size': file.size,
                  'type': file.mimeType,
                  'temp': file.path,
                };
              })
              .rules(const {'doc': 'required|mimes:pdf|max:400'}),
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.error),
    );
    await engine.start();
    addTearDown(engine.stop);

    const boundary = 'socket-boundary-42';
    final content = Uint8List(300 * 1024)..setAll(0, utf8.encode('%PDF-1.7\n'));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${engine.port}/api/upload'),
    );
    request.headers
      ..set('content-type', 'multipart/form-data; boundary=$boundary')
      ..set('accept', 'application/json');
    request
      ..write('--$boundary\r\n')
      ..write('Content-Disposition: form-data; name="title"\r\n\r\n')
      ..write('Quarterly report\r\n')
      ..write('--$boundary\r\n')
      ..write(
        'Content-Disposition: form-data; name="doc"; '
        r'filename="C:\fakepath\report.pdf"'
        '\r\n',
      )
      ..write('Content-Type: application/pdf\r\n\r\n');
    // Several chunks, as a browser sends a large file.
    for (var i = 0; i < content.length; i += 64 * 1024) {
      request.add(content.sublist(i, (i + 64 * 1024).clamp(0, content.length)));
      await request.flush();
    }
    request.write('\r\n--$boundary--\r\n');
    final response = await request.close();
    final body =
        jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;
    expect(response.statusCode, 200, reason: '$body');
    expect(body['title'], 'Quarterly report');
    expect(body['size'], 300 * 1024);
    expect(body['type'], 'application/pdf');
    // Removed once the request scope ends.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(File(body['temp']! as String).existsSync(), isFalse);
  });

  group('a multipart body cut off inside a part (#145)', () {
    late Application app;
    late ServerEngine engine;
    var reached = 0;

    setUp(() async {
      reached = 0;
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (r) => r.post('/upload', (req) async {
              reached++;
              return {'files': (await req.uploadedFiles()).length};
            }),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      engine = ServerEngine(
        app,
        const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
      addTearDown(engine.stop);
    });

    Future<void> slotFreed() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (engine.inFlight != 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the request still holds its slot');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    const boundary = 'cut-42';
    final head = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="doc"; '
      'filename="a.bin"\r\nContent-Type: application/octet-stream\r\n\r\n',
    );

    test('a body that ends inside a file answers 400', () async {
      // Content-Length covers exactly what is sent: the body is complete,
      // its last part is not. The path has no PUT/PATCH/DELETE route, so
      // MethodOverrideMiddleware leaves the body to the route, which reads
      // it and fails.
      final body = [...head, ...List<int>.filled(64 * 1024, 7)];
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      addTearDown(socket.destroy);
      socket
        ..write(
          'POST /upload HTTP/1.1\r\nHost: localhost\r\n'
          'Accept: application/json\r\nConnection: close\r\n'
          'Content-Type: multipart/form-data; boundary=$boundary\r\n'
          'Content-Length: ${body.length}\r\n\r\n',
        )
        ..add(body);
      await socket.flush();
      final reply = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 10));
      expect(reply, startsWith('HTTP/1.1 400'));
      expect(reply, contains('Malformed multipart body'));
      expect(reached, 1, reason: 'the route reads the body');
      await slotFreed();
    });

    test('a client that drops inside a file frees its slot', () async {
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      socket
        ..write(
          'POST /upload HTTP/1.1\r\nHost: localhost\r\n'
          'Content-Type: multipart/form-data; boundary=$boundary\r\n'
          'Content-Length: 1000000\r\n\r\n',
        )
        ..add(head)
        ..add(List<int>.filled(32 * 1024, 7));
      await socket.flush();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (engine.inFlight == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.inFlight, 1);
      socket.destroy();
      await slotFreed();
      expect(reached, 1, reason: 'the route was waiting for its body');
    });
  });
}
