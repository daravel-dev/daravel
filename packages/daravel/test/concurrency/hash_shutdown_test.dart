import 'dart:io';

import 'package:test/test.dart';

/// The symptom as a user meets it, in a process of its own: a command that
/// hashed a password and then shut down printed nothing after the shutdown
/// and still exited 0 (on Linux every time), because the process ended
/// inside `app.shutdown()`. A child isolate shows it differently from a
/// main isolate, so this runs a real process.
void main() {
  test(
    'a process that hashes, then shuts down, prints after the shutdown '
    'and exits 0',
    () async {
      final run = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/concurrency/hash_shutdown_main.dart',
      ]);
      final out = '${run.stdout}';
      expect(out, contains(r'hashed $2y$'), reason: '${run.stderr}');
      expect(
        out,
        contains('after shutdown'),
        reason: 'the process ended inside app.shutdown(): $out${run.stderr}',
      );
      expect(run.exitCode, 0);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    // Not on Windows: there the test runner, once another test file has
    // opened SQLite, holds `.dart_tool/lib/sqlite3.dll`, and the child's
    // `dart run` fails to copy it again. Nothing is lost: on Windows the
    // code before passed this test too; Linux and macOS run it.
    testOn: '!windows',
  );
}
