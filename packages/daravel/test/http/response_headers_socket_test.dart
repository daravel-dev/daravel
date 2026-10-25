import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Regression (Blueprint #22): dart:io shares the value lists of the
/// server's default response headers with every response, so adding a value
/// appended it to the defaults and headers piled up across requests
/// (`x-frame-options: SAMEORIGIN, DENY, DENY, ...`). Only a real socket shows
/// it; TestClient never writes to an HttpResponse.
void main() {
  test('security headers keep one value across many requests', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          api: (r) {
            r.get('/ping', (_) => {'ok': true});
            r.get('/page', (_) => Response.html('<p>x</p>'));
            r.get(
              '/framed',
              (_) => Response.text(
                'x',
                headers: const {'x-frame-options': 'SAMEORIGIN'},
              ),
            );
          },
        )
        .withMiddleware(
          (m) =>
              m.use(const [SecurityHeadersMiddleware(), RequestIdMiddleware()]),
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
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    Future<HttpHeaders> get(String path) async {
      final request = await client.get('127.0.0.1', engine.port!, path);
      final response = await request.close();
      await response.drain<void>();
      return response.headers;
    }

    // JSON: no X-Frame-Options (dart:io used to add SAMEORIGIN); HTML: the
    // middleware's DENY; an explicit value: kept, once.
    const expectedFrame = {
      '/api/ping': null,
      '/api/page': ['DENY'],
      '/api/framed': ['SAMEORIGIN'],
    };
    for (var i = 0; i < 9; i++) {
      final path = expectedFrame.keys.elementAt(i % 3);
      final headers = await get(path);
      expect(headers['x-content-type-options'], [
        'nosniff',
      ], reason: 'request $i');
      expect(
        headers['x-frame-options'],
        expectedFrame[path],
        reason: 'request $i $path',
      );
      // dart:io's own defaults are gone: Daravel's middleware owns them.
      expect(headers['x-xss-protection'], isNull, reason: 'request $i');
      expect(headers['x-request-id'], hasLength(1), reason: 'request $i');
    }
  });
}
