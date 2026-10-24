import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';
import 'make_commands.dart';
import 'new_project.dart';
import 'project_commands.dart';

/// Global `dartisan` (`dart pub global activate dartisan_cli`).
///
/// Outside a project it offers `new` and `key:generate --show`. Inside a
/// project every command is delegated to the project's `bin/dartisan.dart`,
/// so the project's own framework version runs (like `composer` vs
/// `artisan`; BLUEPRINT_V2 §8.1).
final class GlobalDartisanRunner extends CommandRunner<int> {
  GlobalDartisanRunner()
    : super('dartisan', 'Daravel command-line interface (global).') {
    addCommand(NewCommand());
    addCommand(KeyGenerateCommand());
    addCommand(MakeModelCommand());
    addCommand(StubPublishCommand());
  }

  /// Delegates to the project CLI when [args] is not `new` and the current
  /// directory belongs to a Daravel project.
  Future<int> execute(List<String> args) async {
    final project = _projectCli();
    final local = args.isEmpty || args.first == 'new' || args.first == 'help';
    if (project != null && !local && !args.contains('--help')) {
      final process = await Process.start(
        dartExecutable(),
        ['run', p.join('bin', 'dartisan.dart'), ...args],
        workingDirectory: project,
        mode: ProcessStartMode.inheritStdio,
      );
      return process.exitCode;
    }
    try {
      return await run(args) ?? 0;
    } on UsageException catch (error) {
      stderr.writeln(error);
      return 64;
    }
  }

  static String? _projectCli() {
    try {
      final root = ProjectPaths.locate().root;
      return File(p.join(root, 'bin', 'dartisan.dart')).existsSync()
          ? root
          : null;
    } on StateError {
      return null;
    }
  }
}
