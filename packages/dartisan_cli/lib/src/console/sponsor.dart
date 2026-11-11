import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'brand.dart';
import 'console.dart';

/// `~/.dartisan/config.json`: the user's `dartisan` settings, such as
/// whether the closing lines about sponsoring are shown (ADR-036).
final class DartisanUserConfig {
  /// The settings in [home] (`HOME` or `USERPROFILE` by default).
  DartisanUserConfig({String? home}) : home = home ?? userHome();

  /// The user's home directory: `HOME`, else `USERPROFILE`, else `.`.
  static String userHome() =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';

  /// The home directory the settings live under.
  final String home;

  /// `<home>/.dartisan/config.json`.
  File get file => File('$home/.dartisan/config.json');

  Map<String, Object?> _read() {
    try {
      if (file.existsSync()) {
        final json = jsonDecode(file.readAsStringSync());
        if (json is Map<String, Object?>) {
          return json;
        }
      }
    } on FormatException {
      // A file the user broke reads as the defaults.
    }
    return <String, Object?>{};
  }

  /// Whether the closing lines are shown (true unless hidden).
  bool get nudge => _read()['nudge'] != false;

  /// Shows or hides the closing lines, keeping the file's other keys.
  void setNudge(bool value) {
    final json = _read()..['nudge'] = value;
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );
  }
}

/// Starts a program, as [Process.start] (replaced in tests).
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// `dartisan sponsor`: who keeps Daravel going and where to help, without
/// a network call; `--open` opens the page, `--hide` and `--show` turn the
/// closing lines after some commands off and on, `--status` says which.
final class SponsorCommand extends Command<int> {
  /// The command, with the [console] it writes to, the [config] it keeps
  /// the setting in and the [start]er that opens the browser.
  SponsorCommand({
    Console Function()? console,
    DartisanUserConfig? config,
    ProcessStarter? start,
  }) : _console = console ?? Console.new,
       _config = config ?? DartisanUserConfig(),
       _start = start ?? Process.start {
    argParser
      ..addFlag('open', negatable: false, help: 'Open the sponsor page.')
      ..addFlag(
        'hide',
        negatable: false,
        help: 'Never show the closing lines about sponsoring.',
      )
      ..addFlag('show', negatable: false, help: 'Show them again.')
      ..addFlag('status', negatable: false, help: 'Say whether they show.');
  }

  final Console Function() _console;
  final DartisanUserConfig _config;
  final ProcessStarter _start;

  /// The sponsor page.
  static const String url = 'https://$sponsorUrl';

  @override
  String get name => 'sponsor';

  @override
  String get description => 'How to support Daravel, and the sponsor lines.';

  @override
  Future<int> run() async {
    final console = _console();
    final results = argResults!;
    if (results['hide'] == true) {
      _config.setNudge(false);
      console.success('The closing lines about sponsoring are hidden.');
      return 0;
    }
    if (results['show'] == true) {
      _config.setNudge(true);
      console.success('The closing lines about sponsoring show again.');
      return 0;
    }
    if (results['status'] == true) {
      console.writeln(
        _config.nudge
            ? 'Sponsor lines: shown (dartisan sponsor --hide turns them off).'
            : 'Sponsor lines: hidden (${_config.file.path}).',
      );
      return 0;
    }
    if (results['open'] == true) {
      final (program, arguments) = switch (Platform.operatingSystem) {
        'windows' => ('cmd', ['/c', 'start', '', url]),
        'macos' => ('open', [url]),
        _ => ('xdg-open', [url]),
      };
      try {
        await _start(program, arguments);
        console.info('Opened $url');
      } on Object {
        console.writeln(url);
      }
      return 0;
    }
    console.box(title: 'Sponsor Daravel', [
      'Daravel is free and open source. Sponsors pay for the time that',
      'goes into releases, security fixes, Laravel parity and the docs.',
      '',
      url,
      '',
      'dartisan sponsor --open   open the page',
      'dartisan sponsor --hide   never show the closing lines',
    ]);
    return 0;
  }
}
