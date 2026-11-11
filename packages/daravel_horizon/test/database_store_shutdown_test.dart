import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The last job recorded before a stop is in the table: `withHorizon()`
/// flushes the `database` store at shutdown, before the connections close.
/// In a process of its own, since that is where a lost write shows (a
/// process ending inside its shutdown printed nothing and exited 0).
void main() {
  test(
    'a process that records a job and shuts down at once leaves it in '
    'horizon_jobs',
    () async {
      final dir = Directory.systemTemp.createTempSync('horizon_db_stop_');
      final file = p.join(dir.path, 'db.sqlite');
      final run = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/database_store_shutdown_main.dart'],
        environment: {'HORIZON_TEST_DB': file},
      );
      final out = '${run.stdout}';
      expect(
        out,
        contains('store DatabaseHorizonStore'),
        reason: '${run.stderr}',
      );
      expect(out, contains('after shutdown'), reason: '$out${run.stderr}');
      expect(run.exitCode, 0);
      final app = Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'sqlite',
            'DB_DATABASE': file,
          })
          .withLogLevel(LogLevel.critical)
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      // Opened only now: a parent holding sqlite3.dll on Windows keeps the
      // child's `dart run` from copying it.

      final row = await app.run(
        () =>
            DB.table('horizon_jobs').where('uuid', 'last-before-stop').first(),
      );
      expect(row, isNotNull, reason: 'the shutdown wrote the buffer');
    },
    timeout: const Timeout(Duration(minutes: 3)),
    // Not on Windows: there the test runner, once another test file has
    // opened SQLite, holds `.dart_tool/lib/sqlite3.dll`, and the child's
    // `dart run` fails to copy it again (it passes run alone). Linux and
    // macOS run it.
    testOn: '!windows',
  );
}
