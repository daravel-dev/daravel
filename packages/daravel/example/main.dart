import 'dart:io';

import 'package:daravel/daravel.dart';

/// A minimal Daravel application: one JSON route and validation, driven
/// in-process with `Application.handle` (no socket needed).
///
/// In a real project, `dartisan new` creates `bootstrap/app.dart` and
/// `bin/server.dart` serves it with `Application.serveWith(createApp)`.
Future<void> main() async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(const {'APP_ENV': 'local', 'DB_DATABASE': ':memory:'})
      .withRouting(
        apiPrefix: '/api',
        api: (router) {
          router.get('/ping', (_) => {'message': 'pong'});
          router.post('/greet', (request) async {
            final data = await request.validate({
              'name': 'required|string|max:40',
            });
            return {'greeting': 'Hello, ${data.string('name')}!'};
          });
        },
      )
      .create();
  await app.boot();

  final ping = await app.handle(Request.fake(path: '/api/ping'));
  print('${ping.status} ${await ping.bodyText()}');

  final invalid = await app.handle(
    Request.fake(method: 'POST', path: '/api/greet', json: const {}),
  );
  print('${invalid.status} ${await invalid.bodyText()}');

  await app.shutdown();
}
