import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
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
    argParser.addFlag(
      'version',
      abbr: 'V',
      negatable: false,
      help: 'Display this application version.',
    );
    addCommand(NewCommand());
    addCommand(KeyGenerateCommand());
    addCommand(MakeModelCommand());
    addCommand(StubPublishCommand());
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] == true) {
      stdout.writeln('Dartisan CLI $daravelVersion');
      return 0;
    }
    return super.runCommand(topLevelResults);
  }

  /// Whether [args] run in the project's CLI rather than the global one:
  /// inside a project everything is delegated, including `dartisan`,
  /// `dartisan --help` and `dartisan <cmd> --help` (like `php artisan`),
  /// except creating a project (`new`, `help new`).
  static bool delegates(List<String> args, {required bool inProject}) {
    if (!inProject) {
      return false;
    }
    final first = args.firstOrNull;
    final second = args.length > 1 ? args[1] : null;
    final createsProject =
        first == 'new' || (first == 'help' && second == 'new');
    return !createsProject;
  }

  /// Delegates to the project CLI (see [delegates]) when the current
  /// directory belongs to a Daravel project.
  Future<int> execute(List<String> args) async {
    final project = _projectCli();
    if (project != null && delegates(args, inProject: true)) {
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
