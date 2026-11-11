import 'dart:io';

import 'package:daravel/daravel.dart';

/// Child process of `log_output_test.dart`: logs [lines] info lines through
/// the default `ConsoleHandler` while the parent reads nothing from stdout,
/// then says on stderr that logging returned. A console handler writing
/// stdout synchronously would block here as soon as the pipe is full.
Future<void> main(List<String> args) async {
  final lines = int.parse(args.first);
  final logger = Logger(minimumLevel: .info);
  for (var i = 0; i < lines; i++) {
    logger.info('line $i ${'x' * 40}');
  }
  stderr.writeln('logged ${LogLineQueue.droppedTotal}');
  await logger.close();
}
