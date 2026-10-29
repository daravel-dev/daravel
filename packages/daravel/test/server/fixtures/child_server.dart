import 'dart:io';

import 'package:daravel/daravel.dart';

/// A child of `ProcessSupervisor` in tests: answers `GET /` with its
/// index and port, exits on SIGTERM (Windows: when killed). `CRASH_INDEX`
/// names a child that exits with code 3 right away, once per `CRASH_ONCE`
/// marker file.
Future<void> main() async {
  final env = Platform.environment;
  final port = int.parse(env['APP_PORT']!);
  final index = env['DARAVEL_PROCESS_INDEX']!;
  final marker = env['CRASH_ONCE'];
  if (env['CRASH_INDEX'] == index && marker != null) {
    final file = File(marker);
    if (!file.existsSync()) {
      file.writeAsStringSync('crashed');
      exit(3);
    }
  }
  watchSupervisorParent(Platform.environment, () async => exit(0));
  final server = await HttpServer.bind(env['APP_HOST'] ?? '127.0.0.1', port);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await server.close(force: true);
      exit(0);
    });
  }
  await for (final request in server) {
    request.response
      ..headers.contentType = ContentType.json
      ..write(
        '{"index":$index,"port":$port,"count":"${env['DARAVEL_PROCESS_COUNT']}"}',
      );
    await request.response.close();
  }
}
