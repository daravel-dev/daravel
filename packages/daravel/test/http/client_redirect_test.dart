import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The client follows a redirect, and the token of `withToken` does not go
/// along: dart:io drops `Authorization` when it follows one. Pinned here
/// so a change of that behaviour shows.
void main() {
  late Application app;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
  });
  tearDown(() => app.shutdown());

  for (final host in ['127.0.0.1', 'localhost']) {
    test(
      'a redirect to $host on another port does not carry the token',
      () async {
        String? authorization = 'not reached';
        final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => target.close(force: true));
        target.listen((r) {
          authorization = r.headers.value(HttpHeaders.authorizationHeader);
          r.response.close();
        });
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => origin.close(force: true));
        origin.listen((r) {
          r.response
            ..statusCode = 302
            ..headers.set('location', 'http://$host:${target.port}/x')
            ..close();
        });
        final response = await app.run(
          () =>
              Http.withToken('secret-token')
                  .get('http://127.0.0.1:${origin.port}/start'),
        );
        expect(response.status, 200, reason: 'the redirect is followed');
        expect(authorization, isNull, reason: 'without the token');
      },
      tags: 'security',
    );
  }
}
