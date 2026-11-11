import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  test(
    'runDartScript runs a program that opens SQLite while this test '
    'runner holds SQLite open too (on Windows, `dart run` could not)',
    () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      await app.run(() => DB.select('SELECT 1'));

      final run = await runDartScript(
        'test/fixtures/sqlite_main.dart',
        arguments: ['a', 'b'],
        environment: {'RUN_SCRIPT_TEST': 'yes'},
      );
      expect(run.stdout, contains('sqlite 1 a,b'), reason: '${run.stderr}');
      expect(run.stdout, contains('env yes'));
      expect(run.exitCode, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
