import 'dart:io';
import 'dart:isolate';

/// Plain `dart:io` server answering `GET /ping` with `pong`: the reference
/// for the framework overhead of scenario 1 (BLUEPRINT_V2 §10.2: ≤ 25%).
/// Runs `APP_ISOLATES` isolates sharing the port, like Daravel's supervisor.
Future<void> main() async {
  final port = int.parse(Platform.environment['APP_PORT'] ?? '8000');
  final isolates = int.parse(Platform.environment['APP_ISOLATES'] ?? '1');
  for (var i = 1; i < isolates; i++) {
    await Isolate.spawn(_serve, port);
  }
  await _serve(port);
}

Future<void> _serve(int port) async {
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    port,
    shared: true,
  );
  await for (final request in server) {
    final response = request.response;
    if (request.uri.path == '/ping' || request.uri.path == '/up') {
      response.headers.contentType = ContentType.text;
      response.write('pong');
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }
}
