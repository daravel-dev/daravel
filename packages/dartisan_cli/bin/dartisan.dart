import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

/// Global entrypoint: `dartisan new <name>`, or any project command when run
/// inside a Daravel project (delegated to its `bin/dartisan.dart`).
Future<void> main(List<String> args) async {
  exitCode = await GlobalDartisanRunner().execute(args);
}
