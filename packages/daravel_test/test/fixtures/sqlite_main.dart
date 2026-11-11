// Run by `process_test.dart` through `runDartScript`: opens SQLite, as a
// program whose test runner holds `sqlite3.dll` open too.
import 'dart:io';

import 'package:daravel/daravel.dart';

Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .create();
  await app.boot();
  final one = await app.run(() => DB.select('SELECT 1 AS one'));
  stdout.writeln('sqlite ${one.single['one']} ${args.join(',')}');
  stdout.writeln('env ${Platform.environment['RUN_SCRIPT_TEST']}');
  await app.shutdown();
}
