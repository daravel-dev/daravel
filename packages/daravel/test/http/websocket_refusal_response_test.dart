import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _Counting implements TerminableMiddleware {
  int handled = 0;
  int deferred = 0;
  final List<int> statuses = [];

  @override
  Future<Response> handle(Request request, Next next) {
    handled++;
    request.defer(() => deferred++);
    return next(request);
  }

  @override
  void terminate(Request request, Response response) =>
      statuses.add(response.status);
}

void main() {
  test(
    'a direct WebSocket response answers and terminates an ordinary request',
    () async {
      final counting = _Counting();
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withMiddleware((m) => m.use([counting]))
          .withRouting(
            apiPrefix: '',
            api: (router) {
              router.get(
                '/direct',
                (_) => Response.webSocket((socket, _) {
                  socket.listen(socket.add);
                }),
              );
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final engine = ServerEngine(
        app,
        const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
      addTearDown(engine.stop);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${engine.port}/direct'),
      );
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 426);
      expect(response.headers.value('upgrade'), 'websocket');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (counting.statuses.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(counting.statuses, [426]);
      expect(counting.handled, 1);
      expect(counting.deferred, 1);
      expect(engine.inFlight, 0);
    },
  );
}
