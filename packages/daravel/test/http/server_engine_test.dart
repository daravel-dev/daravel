import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('the access log measures the response, not deferred work', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get('/slow-defer', (request) {
              request.defer(
                () => Future<void>.delayed(const Duration(milliseconds: 400)),
              );
              return 'ok';
            });
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final memory = MemoryHandler();
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [memory]),
    );
    await engine.start();
    addTearDown(engine.stop);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${engine.port}/slow-defer'),
    );
    await (await request.close()).drain<void>();

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    LogRecord? access;
    while (access == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      access = memory.records
          .where((r) => r.message.startsWith('GET /slow-defer 200'))
          .firstOrNull;
    }
    expect(access, isNotNull, reason: 'access log line was not written');
    final ms = double.parse(
      RegExp(r'([\d.]+)ms$').firstMatch(access!.message)!.group(1)!,
    );
    expect(ms, lessThan(300));
  });
}
