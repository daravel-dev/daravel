// Run by `hash_shutdown_test.dart` as a process of its own: a command's
// shape, whose last step is the shutdown after hashing a password. The
// process must print the line after the shutdown, and exit 0 only then.
import 'dart:io';

import 'package:daravel/daravel.dart';

Future<void> main() async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({
        'APP_ENV': 'testing',
        'APP_KEY': 'base64:${'A' * 43}=',
        'DB_DATABASE': ':memory:',
        'HASH_DRIVER': 'bcrypt',
        'BCRYPT_ROUNDS': '4',
      })
      .withLogLevel(LogLevel.critical)
      .create();
  await app.boot();
  final hash = await app.run(() => Hash.make('secret'));
  stdout.writeln('hashed ${hash.substring(0, 4)}');
  await app.shutdown();
  stdout.writeln('after shutdown');
}
