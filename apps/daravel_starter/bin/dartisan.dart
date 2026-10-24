import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

import '../bootstrap/app.dart';
import '../bootstrap/commands.dart';

/// Project-bound CLI: `dart run bin/dartisan.dart <command>`.
Future<void> main(List<String> args) async {
  exitCode = await DartisanRunner(createApp, commands: commands).execute(args);
}
