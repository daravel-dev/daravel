import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// gzip and 304s through a real socket (ServerEngine), not only TestClient.
void main() {
  late ServerEngine engine;
  late HttpClient client;
  final big = {
    'items': List.generate(300, (i) => {'id': i, 'name': 'item $i'}),
  };

  setUp(() async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          api: (r) => r.get('/big', (_) => big).middleware(const [
            'cache.headers:public;max_age=60;etag',
          ]),
        )
        .withMiddleware((m) => m.use(const [CompressResponseMiddleware()]))
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.error),
    );
    await engine.start();
    addTearDown(engine.stop);
    client = HttpClient()..autoUncompress = false;
    addTearDown(() => client.close(force: true));
  });

  Future<(HttpClientResponse, List<int>)> send(
    String method, {
    Map<String, String> headers = const {},
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${engine.port}/api/big'),
    );
    headers.forEach(request.headers.set);
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    return (response, bytes);
  }

  test('gzip body, length and HEAD over the socket', () async {
    final (response, bytes) = await send(
      'GET',
      headers: {'accept-encoding': 'gzip'},
    );
    expect(response.statusCode, 200);
    expect(response.headers.value('content-encoding'), 'gzip');
    expect(response.contentLength, bytes.length, reason: 'compressed length');
    expect(jsonDecode(utf8.decode(gzip.decode(bytes))), big);

    final (head, headBytes) = await send(
      'HEAD',
      headers: {'accept-encoding': 'gzip'},
    );
    expect(head.statusCode, 200);
    expect(headBytes, isEmpty);
    expect(head.contentLength, bytes.length);

    // HttpClient asks for gzip by default.
    final (plain, plainBytes) = await send(
      'GET',
      headers: {'accept-encoding': 'identity'},
    );
    expect(plain.headers.value('content-encoding'), isNull);
    expect(jsonDecode(utf8.decode(plainBytes)), big);

    final etag = response.headers.value('etag')!;
    final (notModified, empty) = await send(
      'GET',
      headers: {'accept-encoding': 'gzip', 'if-none-match': etag},
    );
    expect(notModified.statusCode, 304);
    expect(empty, isEmpty);
  });
}
