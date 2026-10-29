import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

/// Runs a `ProcessSupervisor` of two `child_server.dart` on the port given
/// as the first argument, prints `ready` and waits: the test kills this
/// process outright and checks that the children go with it.
Future<void> main(List<String> args) async {
  final supervisor = ProcessSupervisor(
    executable: Platform.resolvedExecutable,
    arguments: [p.join('test', 'server', 'fixtures', 'child_server.dart')],
    options: ServeOptions(
      host: '127.0.0.1',
      port: int.parse(args.first),
      readyTimeout: const Duration(seconds: 60),
    ),
    processes: 2,
    logger: Logger(minimumLevel: .warning),
    handleSignals: false,
  );
  await supervisor.start();
  stdout.writeln('ready');
  await supervisor.done;
}
