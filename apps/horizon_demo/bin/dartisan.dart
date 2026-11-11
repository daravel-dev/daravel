import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

import '../bootstrap/app.dart';
import '../bootstrap/commands.dart';

/// Dartisan CLI runner: `dart run bin/dartisan.dart <command>`, including
/// `horizon`, `horizon:status` and `horizon:snapshot`.
Future<void> main(List<String> args) async {
  exitCode = await DartisanRunner(createApp, commands: commands).execute(args);
}
