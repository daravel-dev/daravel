import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

import '../bootstrap/app.dart';

/// Project-bound CLI: `dart run bin/dartisan.dart <command>`.
Future<void> main(List<String> args) async {
  exitCode = await DartisanRunner(createApp).execute(args);
}
