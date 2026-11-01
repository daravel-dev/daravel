// Compiled by `aot_test.dart`: closures cross to a worker in a native binary,
// and the process ends without a shutdown.
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/concurrency.dart';

Future<void> main() async {
  final base = 20;
  final results = await Concurrency.run<String>([
    () => '${base + 1}:${Isolate.current.debugName}',
    () => '${base + 2}:${Isolate.current.debugName}',
  ]);
  stdout.writeln(results.join(','));
}
