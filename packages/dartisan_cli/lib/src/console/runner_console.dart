import 'dart:async';

import 'package:args/command_runner.dart';

import 'command_list.dart';
import 'console.dart';

/// The appearance of a `dartisan` runner (Blueprint #137 §3.2): the global
/// `--no-color` and `--ansi` flags, the banner and grouped commands on a
/// terminal, `dartisan list`, and option names coloured in `help`.
///
/// Off a terminal (`dartisan | cat`, CI) the usage stays `package:args`'
/// plain text, and no command's own output changes.
mixin DartisanConsole on CommandRunner<int> {
  Console? _injected;
  Console? _console;
  Set<String> _project = const {};

  /// The console of this run.
  Console get console => _console ??=
      _injected ?? Console.forFlags(noColor: _noColor, ansi: _ansi);
  bool _noColor = false;
  bool _ansi = false;

  /// Adds the global flags and `list`; [console] replaces the detected one
  /// (tests), [project] names the project's own commands.
  void setUpConsole({Console? console, Set<String> project = const {}}) {
    _injected = console;
    _project = project;
    argParser
      ..addFlag(
        'no-color',
        negatable: false,
        help: 'Plain output (also NO_COLOR, DARTISAN_NO_COLOR=1).',
      )
      ..addFlag(
        'ansi',
        negatable: false,
        help: 'Force colors, for a pager such as less -R.',
      );
    addCommand(ListCommand(this, () => this.console, project: project));
  }

  /// The project's own commands, listed last as `project`.
  Set<String> get projectCommands => _project;

  @override
  Future<int?> run(Iterable<String> args) {
    final all = args.toList();
    final end = all.indexOf('--');
    final options = end < 0 ? all : all.sublist(0, end);
    final noColor = options.contains('--no-color');
    final ansi = options.contains('--ansi');
    final rest = [
      for (final arg in options)
        if (arg != '--no-color' && arg != '--ansi') arg,
      if (end >= 0) ...all.sublist(end),
    ];
    // Built on first use: a command that never prints usage does not
    // touch the terminal.
    _noColor = noColor;
    _ansi = ansi;
    _console = null;
    final help =
        rest.firstOrNull == 'help' ||
        rest.contains('--help') ||
        rest.contains('-h');
    if (!help || !console.color) {
      return super.run(rest);
    }
    // `package:args` prints a command's usage with print(): colour its
    // option names on the way.
    return runZoned(
      () => super.run(rest),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) =>
            parent.print(zone, colorizeOptions(console, line)),
      ),
    );
  }

  @override
  String get usage {
    final console = this.console;
    if (!console.terminal) {
      return super.usage;
    }
    return '${renderBanner(console)}\n\n'
        '${renderCommandList(
          console,
          executable: executableName,
          globalOptions: argParser,
          entries: commandEntries(commands, project: _project),
        )}';
  }

  @override
  void printUsage() => console.writeln(usage);
}
