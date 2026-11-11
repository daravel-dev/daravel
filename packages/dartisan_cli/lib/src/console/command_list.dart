import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;

import 'brand.dart';
import 'console.dart';

/// One command of `dartisan list`.
final class CommandEntry {
  /// [name] with [description], in [group] (`''` for the top one).
  const CommandEntry(this.name, this.description, this.group);

  /// The command's name (`make:model`).
  final String name;

  /// The first line of its description.
  final String description;

  /// The part of the name before `:`, `project` for a project's own
  /// commands, or `''`.
  final String group;

  /// `{name, description, group}` for `list --format=json`.
  Map<String, String> toJson() => {
    'name': name,
    'description': description,
    'group': group,
  };
}

/// The visible commands of [commands] (aliases once), grouped as
/// `php artisan list` does: by the part of the name before `:`, the
/// commands without one first, [project] commands last as `project`;
/// groups and names in alphabetical order.
List<CommandEntry> commandEntries(
  Map<String, Command<Object?>> commands, {
  Set<String> project = const {},
}) {
  final entries = [
    for (final MapEntry(key: name, value: command) in commands.entries)
      if (name == command.name && !command.hidden)
        CommandEntry(
          name,
          command.summary,
          project.contains(name)
              ? 'project'
              : name.contains(':')
              ? name.substring(0, name.indexOf(':'))
              : '',
        ),
  ];
  int rank(String group) => switch (group) {
    '' => 0,
    'project' => 2,
    _ => 1,
  };
  entries.sort((a, b) {
    final byRank = rank(a.group).compareTo(rank(b.group));
    if (byRank != 0) {
      return byRank;
    }
    final byGroup = a.group.compareTo(b.group);
    return byGroup != 0 ? byGroup : a.name.compareTo(b.name);
  });
  return entries;
}

/// The banner of `dartisan` on a terminal: the word-mark, the versions and
/// one dim line about the sponsors.
String renderBanner(Console console, {String? dart, String? os}) {
  final sdk = dart ?? Platform.version.split(' ').first;
  final system = os ?? Platform.operatingSystem;
  final dot = console.unicode ? ' · ' : ' - ';
  final heart = console.unicode ? ' ♥ ' : ': ';
  final lines = [
    console.style(dartisanWordmark[0], fg: Ansi.red, bold: true),
    '${console.style(dartisanWordmark[1], fg: Ansi.red, bold: true)}  '
        'Daravel $daravelVersion${dot}Dart $sdk$dot$system',
    '${dartisanWordmark[2]}  '
        '${console.style('Made with the help of our sponsors$heart$sponsorUrl', dim: true)}',
  ];
  return lines.join('\n');
}

/// The usage of [runner] with its commands grouped ([commandEntries]):
/// `Usage:`, the global options, then the commands, coloured by [console].
String renderCommandList(
  Console console, {
  required String executable,
  required ArgParser globalOptions,
  required List<CommandEntry> entries,
}) {
  final buffer = StringBuffer()
    ..writeln(console.style('Usage:', fg: Ansi.yellow))
    ..writeln('  $executable <command> [arguments]')
    ..writeln()
    ..writeln(console.style('Global options:', fg: Ansi.yellow))
    ..writeln(colorizeOptions(console, _indent(globalOptions.usage)))
    ..writeln()
    ..writeln(console.style('Available commands:', fg: Ansi.yellow));
  final width = entries.fold(
    0,
    (w, e) => e.name.length > w ? e.name.length : w,
  );
  String? group;
  for (final entry in entries) {
    if (entry.group != group) {
      group = entry.group;
      if (group.isNotEmpty) {
        buffer.writeln(' ${console.style(group, fg: Ansi.yellow)}');
      }
    }
    buffer.writeln(
      '  ${console.style(entry.name.padRight(width), fg: Ansi.green)}  '
      '${entry.description}',
    );
  }
  buffer.writeln();
  buffer.write(
    'Run "$executable help <command>" for more information about a command.',
  );
  return buffer.toString();
}

String _indent(String text) =>
    text.split('\n').map((line) => line.isEmpty ? line : '  $line').join('\n');

final RegExp _option = RegExp(r'^(\s*)((?:-\w, )?--?[\w-]+(?:=<[^>]+>)?)');

/// [usage] (a `package:args` usage text) with each option name in green,
/// when [console] colours; unchanged otherwise.
String colorizeOptions(Console console, String usage) => !console.color
    ? usage
    : usage
          .split('\n')
          .map(
            (line) => line.replaceFirstMapped(
              _option,
              (m) => '${m[1]}${console.style(m[2]!, fg: Ansi.green)}',
            ),
          )
          .join('\n');

/// `dartisan list`: the commands, grouped; `--raw` for their names, one per
/// line, and `--format=json` for `[{name, description, group}]`.
final class ListCommand extends Command<int> {
  /// The list of the commands [runner] has, written to [console].
  ListCommand(this._runner, this._console, {this.project = const {}}) {
    argParser
      ..addFlag(
        'raw',
        negatable: false,
        help: 'Command names only, one per line.',
      )
      ..addOption(
        'format',
        allowed: ['txt', 'json'],
        defaultsTo: 'txt',
        help: 'The output format.',
      );
  }

  final CommandRunner<int> _runner;
  final Console Function() _console;

  /// The project's own commands, listed last as `project`.
  final Set<String> project;

  @override
  String get name => 'list';

  @override
  String get description => 'List the commands.';

  @override
  Future<int> run() async {
    final console = _console();
    final results = argResults!;
    final entries = commandEntries(_runner.commands, project: project);
    if (results['format'] == 'json') {
      console.writeln(jsonEncode([for (final e in entries) e.toJson()]));
    } else if (results['raw'] == true) {
      for (final entry in entries) {
        console.writeln(entry.name);
      }
    } else {
      if (console.terminal) {
        console
          ..writeln(renderBanner(console))
          ..writeln();
      }
      console.writeln(
        renderCommandList(
          console,
          executable: _runner.executableName,
          globalOptions: _runner.argParser,
          entries: entries,
        ),
      );
    }
    return 0;
  }
}
