import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'closures reach a worker in a native binary, which then exits',
    () async {
      final dir = Directory.systemTemp.createTempSync('daravel_concurrency');
      addTearDown(() => dir.deleteSync(recursive: true));
      final binary = p.join(
        dir.path,
        Platform.isWindows ? 'aot_main.exe' : 'aot_main',
      );
      final compile = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'test/concurrency/aot_main.dart',
        '-o',
        binary,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}${compile.stdout}');
      final run = await Process.run(
        binary,
        const [],
      ).timeout(const Duration(seconds: 30));
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect('${run.stdout}'.trim(), '21:daravel-compute,22:daravel-compute');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
