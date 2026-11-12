/// `model:sync` without compiling the application (#329): it reads the
/// models from their sources and needs only a database connection, so it
/// runs from a small program written into the project's `.dart_tool`,
/// which imports the framework, the CLI and the database drivers, never
/// the application's code. A sync whose output no longer compiles can then
/// be repaired by syncing again.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'project_commands.dart';

/// Where the program is written, under the project root: `.dart_tool` is
/// never analyzed and never committed.
const String modelSyncEntryPath = '.dart_tool/dartisan/model_sync.dart';

/// The drivers a project registers, as the program learns them: the
/// project's `bootstrap/database.dart` registry when it has one, else the
/// driver packages its `pubspec.yaml` depends on (`daravel_mysql`).
/// `sqlite` and `pgsql` are built into `package:daravel`.
({bool registry, bool mysql}) projectDrivers(String root) {
  final registry = File(p.join(root, 'bootstrap', 'database.dart'));
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  return (
    registry: registry.existsSync(),
    mysql:
        pubspec.existsSync() &&
        RegExp(
          r'^\s+daravel_mysql\s*:',
          multiLine: true,
        ).hasMatch(pubspec.readAsStringSync()),
  );
}

/// The program `model:sync` runs: imports and one call, nothing else (no
/// value from the environment is ever written into it).
String modelSyncEntrySource({required bool registry, required bool mysql}) {
  final lines = <String>[
    '// Written by `dartisan model:sync` on every run; not part of the',
    '// application. It compiles the framework, the CLI and the database',
    "// drivers only, so the models' generated code need not compile.",
    "import 'dart:io';",
    '',
    "import 'package:daravel/daravel.dart';",
    "import 'package:dartisan_cli/dartisan_cli.dart';",
    if (!registry && mysql)
      "import 'package:daravel_mysql/daravel_mysql.dart';",
    if (registry) "import '../../bootstrap/database.dart';",
    '',
    'Future<void> main(List<String> args) async {',
    '  exitCode = await runModelSyncEntry(',
    '    args,',
    if (registry)
      '    drivers: databaseDrivers,'
    else if (mysql) ...[
      '    drivers: <String, DatabaseDriverFactory>{',
      "      'mysql': MySqlDriver.fromConfig,",
      "      'mariadb': MySqlDriver.fromConfig,",
      '    },',
    ] else
      '    drivers: const <String, DatabaseDriverFactory>{},',
    '  );',
    '}',
    '',
  ];
  return lines.join('\n');
}

/// Writes the program into the project at [root] and runs it with [args]
/// (the arguments of `model:sync`), the output going to this terminal.
/// `dart run` resolves `daravel` and `dartisan_cli` through the project's
/// `pubspec.lock`, so the project's versions write its models.
Future<int> spawnModelSync(String root, List<String> args) async {
  final drivers = projectDrivers(root);
  if (!drivers.registry && drivers.mysql) {
    stdout.writeln(
      'model:sync: using daravel_mysql from pubspec.yaml; a '
      'bootstrap/database.dart registry (databaseDrivers) names the drivers '
      'explicitly.',
    );
  }
  final entry = File(p.join(root, modelSyncEntryPath))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      modelSyncEntrySource(registry: drivers.registry, mysql: drivers.mysql),
    );
  final process = await Process.start(
    dartExecutable(),
    ['run', entry.path, ...args],
    workingDirectory: root,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

/// The program's body: `model:sync` in an application made of the project's
/// environment (`.env`, `DB_*`) and [drivers] only, no routes, providers or
/// models compiled. A connection the application configures in code is not
/// there: the error says so and points to `--boot`.
Future<int> runModelSyncEntry(
  List<String> args, {
  Map<String, DatabaseDriverFactory> drivers =
      const <String, DatabaseDriverFactory>{},
}) async {
  Application app() =>
      Application.configure(basePath: Directory.current.path)
          .withDatabaseDrivers(drivers)
          .withLogLevel(LogLevel.warning)
          .create();
  try {
    return await (CommandRunner<int>(
          'dartisan',
          'model:sync without compiling the application',
        )..addCommand(ModelSyncCommand(app))).run([
          'model:sync',
          ...args,
          ModelSyncCommand.inEntryFlag,
        ]) ??
        0;
  } on UsageException catch (error) {
    stderr.writeln(error);
    return 64;
  }
}

/// The regions `model:sync` writes and `--reset-regions` empties; never
/// `statics`, which `make:model` fills once and the application owns.
const List<String> resettableRegions = ['accessors', 'relation-path'];

/// Empties the [resettableRegions] of the model files in [dir] ([only], one
/// file name without extension, or all), so an application whose generated
/// code no longer compiles compiles again. Writes nothing with [dryRun].
/// Returns what was (or would be) emptied, one line per region.
List<String> resetModelRegions(
  Directory dir, {
  String? only,
  bool dryRun = false,
}) {
  final emptied = <String>[];
  if (!dir.existsSync()) {
    return emptied;
  }
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    if (only != null && p.basenameWithoutExtension(file.path) != only) {
      continue;
    }
    var source = file.readAsStringSync();
    final before = source;
    for (final region in resettableRegions) {
      final start = '// <dartisan:$region>';
      final end = '// </dartisan:$region>';
      final from = source.indexOf(start);
      final to = source.indexOf(end);
      if (from == -1 || to < from) {
        continue;
      }
      final inside = source.substring(from + start.length, to);
      if (inside.trim().isEmpty) {
        continue;
      }
      // Keep the indentation of the closing marker.
      final lineStart = source.lastIndexOf('\n', to) + 1;
      final indent = source.substring(lineStart, to);
      source =
          '${source.substring(0, from + start.length)}\n$indent'
          '${source.substring(to)}';
      emptied.add('${p.basename(file.path)}: the $region region');
    }
    if (source != before && !dryRun) {
      file.writeAsStringSync(source);
    }
  }
  return emptied;
}

/// The compile errors in [output] (`dart run` of the project's CLI) that
/// fall inside a region `model:sync` writes, as `file:line (region)`: the
/// generated code is what stops the application from compiling.
List<String> errorsInGeneratedRegions(String output, String root) {
  final found = <String>[];
  final error = RegExp(r'^(.+?\.dart):(\d+):\d+: Error', multiLine: true);
  final regionLine = RegExp(r'//\s*<(/?)dartisan:([\w-]+)>');
  for (final match in error.allMatches(output)) {
    final path = match.group(1)!.trim();
    final line = int.parse(match.group(2)!);
    final file = File(p.isAbsolute(path) ? path : p.join(root, path));
    if (!file.existsSync()) {
      continue;
    }
    final lines = file.readAsLinesSync();
    String? open;
    for (var i = 0; i < lines.length && i < line; i++) {
      final marker = regionLine.firstMatch(lines[i]);
      if (marker != null) {
        open = marker.group(1)!.isEmpty ? marker.group(2) : null;
      }
    }
    if (open != null && resettableRegions.contains(open)) {
      found.add('${p.relative(file.path, from: root)}:$line ($open)');
    }
  }
  return found.toSet().toList();
}

/// What `model:sync --boot` says after the project's CLI failed with
/// [output]: when the application did not compile, always how to get out,
/// since the error is often in code that uses a generated accessor, not
/// in the generated lines (#329); and, when errors fall inside a generated
/// region, which ones. Nothing for another failure.
List<String> bootFailureHints(String output, String root) {
  if (!RegExp(r'\.dart:\d+:\d+: Error', multiLine: true).hasMatch(output)) {
    return const [];
  }
  final generated = errorsInGeneratedRegions(output, root);
  return [
    if (generated.isNotEmpty)
      'model:sync: the application does not compile because of lines '
          'model:sync wrote: ${generated.join(', ')}.',
    'model:sync: if model:sync output is the cause (an accessor whose type '
        'changed), run dartisan model:sync without --boot, which does not '
        'compile the application, or model:sync --reset-regions.',
  ];
}
