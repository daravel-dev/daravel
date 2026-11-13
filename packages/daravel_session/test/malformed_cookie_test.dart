import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:test/test.dart';

/// A cookie whose encrypted payload has a field of the wrong type (a
/// number for its `mac`), as one planted by another application on the
/// parent domain may be, is ignored like any cookie that does not decrypt:
/// the request is answered, not a 500. The same payload in
/// `X-XSRF-TOKEN` is a token mismatch (419). Over a socket.
void main() {
  late Directory base;
  late Application app;
  late ServerEngine engine;
  final malformed = base64.encode(
    utf8.encode(jsonEncode({'iv': '', 'value': '', 'mac': 123})),
  );

  setUp(() async {
    base = Directory.systemTemp.createTempSync('malformed_cookie');
    app = Application.configure(basePath: base.path)
        .withEnv({
          'APP_ENV': 'testing',
          'APP_NAME': 'My App',
          'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'DB_DATABASE': ':memory:',
          'SESSION_DRIVER': 'array',
        })
        .withLogLevel(LogLevel.critical)
        .withSession()
        .withRouting(
          web: (router) => router.group((r) {
            r.get('/hello', (request) => {'ok': true});
            r.post('/submit', (request) => {'ok': true});
          }, middleware: const ['web']),
        )
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      ServeOptions.fromEnv(Env.fromMap(const {}), host: '127.0.0.1', port: 0),
      kernel: app.kernel,
      logger: Logger(minimumLevel: .critical),
    );
    await engine.start();
  });

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<(int, String)> send(
    String method,
    String path,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${engine.port}$path'),
      );
      headers.forEach(request.headers.set);
      if (method == 'POST') {
        request.headers.contentType = ContentType.json;
        request.write('{}');
      }
      final response = await request.close();
      return (response.statusCode, await utf8.decodeStream(response));
    } finally {
      client.close(force: true);
    }
  }

  test('a planted cookie is ignored: 200', () async {
    for (final name in ['other', 'my_app_session', 'XSRF-TOKEN']) {
      final (status, body) = await send('GET', '/hello', {
        'cookie': '$name=$malformed',
      });
      expect(status, 200, reason: name);
      expect(jsonDecode(body), {'ok': true});
    }
  });

  test('the same payload in X-XSRF-TOKEN is a 419', () async {
    final (status, body) = await send('POST', '/submit', {
      'x-xsrf-token': malformed,
    });
    expect(status, 419);
    expect(jsonDecode(body), {'message': 'CSRF token mismatch.'});
  });
}
