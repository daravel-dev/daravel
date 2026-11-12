import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:path/path.dart' as p;

import 'console/console.dart';
import 'console/nudges.dart';
import 'console/runner_console.dart';
import 'generator.dart';
import 'make_commands.dart';
import 'new_project.dart';
import 'project_commands.dart';
import 'request_sync.dart';
import 'upgrade_command.dart';

/// Global `dartisan` (`dart pub global activate dartisan_cli`).
///
/// Outside a project it offers `new` and `key:generate --show`. Inside a
/// project every command is delegated to the project's `bin/dartisan.dart`,
/// so the project's own framework version runs (like `composer` vs
/// `artisan`; BLUEPRINT_V2 §8.1). The commands that only rewrite sources
/// ([runsFromSource], `request:sync`) run in the project's own
/// `dartisan_cli` instead, without compiling the application: they are
/// what brings a project that does not compile back to one that does.
final class GlobalDartisanRunner extends CommandRunner<int>
    with DartisanConsole {
  /// The commands that work outside a project, such as `new`; [console]
  /// replaces the detected one (tests).
  GlobalDartisanRunner({
    Console? console,
    Nudges Function(Console console)? nudges,
  }) : super('dartisan', 'Daravel command-line interface (global).') {
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
    addCommand(RequestSyncCommand());
    addCommand(UpgradeCommand());
    addCommand(SelfUpdateCommand());
    setUpConsole(console: console, nudges: nudges);
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
  /// except creating a project (`new`) and upgrading (`upgrade`,
  /// `self-update`), which also work for projects whose CLI predates them.
  static bool delegates(List<String> args, {required bool inProject}) {
    if (!inProject) {
      return false;
    }
    final command = _command(args);
    return !_globalOnly.contains(command) && !_fromSource.contains(command);
  }

  /// Whether [args] name a command that only reads and writes the
  /// project's sources (`request:sync`): inside a project it runs in the
  /// project's own `dartisan_cli` (`dart run dartisan_cli:dartisan`), so
  /// the project's framework version writes the code, and the application
  /// is not compiled. A request typed `FormRequest<StoreNoteRequestInput>`
  /// before `StoreNoteRequestInput` exists stops every command of the
  /// project's `bin/dartisan.dart` from compiling, the one that writes the
  /// type included.
  static bool runsFromSource(List<String> args, {required bool inProject}) =>
      inProject && _fromSource.contains(_command(args));

  static String? _command(List<String> args) {
    final first = args.firstOrNull;
    return first == 'help' && args.length > 1 ? args[1] : first;
  }

  static const Set<String> _globalOnly = {'new', 'upgrade', 'self-update'};
  static const Set<String> _fromSource = {'request:sync'};

  /// Set in the environment of the project's `dartisan_cli` that runs a
  /// [runsFromSource] command, so it runs the command instead of handing
  /// it on again.
  static const String inProjectPackage = 'DARTISAN_IN_PROJECT_PACKAGE';

  /// Delegates to the project CLI (see [delegates]) when the current
  /// directory belongs to a Daravel project.
  ///
  /// [environment] replaces the process environment and [directory] the
  /// current one, where the project is looked for (tests).
  Future<int> execute(
    List<String> args, {
    Map<String, String>? environment,
    String? directory,
  }) async {
    final project = _projectCli(directory);
    if (project != null && delegates(args, inProject: true)) {
      final process = await Process.start(
        dartExecutable(),
        ['run', p.join('bin', 'dartisan.dart'), ...args],
        workingDirectory: project,
        mode: ProcessStartMode.inheritStdio,
      );
      return process.exitCode;
    }
    final env = environment ?? Platform.environment;
    if (project != null &&
        runsFromSource(args, inProject: true) &&
        env[inProjectPackage] != '1') {
      // The project's dartisan_cli, as its pubspec.lock resolves it: only
      // the CLI and the framework compile, never the application. A
      // project on a dartisan_cli older than this hands the command to
      // its bin/dartisan.dart, as before.
      final process = await Process.start(
        dartExecutable(),
        ['run', 'dartisan_cli:dartisan', ...args],
        workingDirectory: project,
        environment: {inProjectPackage: '1'},
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

  static String? _projectCli([String? directory]) {
    try {
      final root = ProjectPaths.locate(directory).root;
      return File(p.join(root, 'bin', 'dartisan.dart')).existsSync()
          ? root
          : null;
    } on StateError {
      return null;
    }
  }
}
