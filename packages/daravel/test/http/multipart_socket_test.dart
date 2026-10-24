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
}
