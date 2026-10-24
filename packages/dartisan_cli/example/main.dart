import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

/// A project-bound CLI: what `bin/dartisan.dart` contains in a project
/// created by `dartisan new`. Try `dart run example/main.dart route:list`.
Application createApp() =>
    Application.configure(basePath: Directory.current.path)
        .withEnv(const {'APP_ENV': 'local', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '/api',
          api: (router) => router.get('/ping', (_) => 'pong').name('ping'),
        )
        .create();

Future<void> main(List<String> args) async {
  exitCode = await DartisanRunner(createApp)
      .execute(args.isEmpty ? const ['route:list'] : args);
}
