import 'dart:io';

import 'brand.dart';
import 'console.dart';
import 'sponsor.dart';

/// The closing lines after a successful command (ADR-036): they thank or
/// inform, never ask; one link; no amounts.
const List<String> nudgeLines = [
  'Daravel is kept going by its sponsors. Thank you: $sponsorUrl',
  'The time behind each Daravel release is paid for by sponsors: '
      '$sponsorUrl',
  'Thanks for building with Daravel. The people who keep it going: '
      '$sponsorUrl',
];

/// The line of [day]: the same all day, the next one the day after.
String nudgeFor(DateTime day) {
  final days =
      DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  return nudgeLines[days % nudgeLines.length];
}

/// The commands whose success may end with a line (ADR-036 §2.4); `migrate`
/// joins them when it created the project's `migrations` table.
const Set<String> nudgeCommands = {
  'new',
  'build',
  'upgrade',
  'self-update',
  'test',
};

/// Variables that mean continuous integration: never a line there.
const List<String> ciVariables = [
  'CI',
  'GITHUB_ACTIONS',
  'GITLAB_CI',
  'TF_BUILD',
];

/// Whether and when to print a closing line: never in CI, off a terminal,
/// with `DARTISAN_NO_NUDGE=1` or after `dartisan sponsor --hide`, and at
/// most once every 24 hours per machine (`~/.dartisan/last_nudge`, wall
/// clock).
final class Nudges {
  /// The lines for [console], with the [environment], user [config] and
  /// clock ([now]) given for tests.
  Nudges(
    this.console, {
    Map<String, String>? environment,
    DartisanUserConfig? config,
    DateTime Function()? now,
  }) : environment = environment ?? Platform.environment,
       config = config ?? DartisanUserConfig(),
       now = now ?? DateTime.now;

  /// Where the line is written.
  final Console console;

  /// The process environment.
  final Map<String, String> environment;

  /// The user's settings (`nudge`).
  final DartisanUserConfig config;

  /// The wall clock: the quota is about the user's day, not domain time.
  final DateTime Function() now;

  /// How long after one line the next may come.
  static const Duration quota = Duration(hours: 24);

  /// Whether no line may be printed at all.
  bool get silenced =>
      ciVariables.any((name) => (environment[name] ?? '').isNotEmpty) ||
      environment['DARTISAN_NO_NUDGE'] == '1' ||
      !console.terminal ||
      !config.nudge;

  /// `<home>/.dartisan/last_nudge`: when the last line was printed.
  File get stamp => File('${config.home}/.dartisan/last_nudge');

  /// After a successful command: the line of the day, unless [silenced]
  /// or one was printed less than [quota] ago. Whether it printed.
  bool afterSuccess() {
    if (silenced) {
      return false;
    }
    final at = now();
    try {
      if (stamp.existsSync()) {
        final last = DateTime.tryParse(stamp.readAsStringSync().trim());
        if (last != null && at.difference(last) < quota) {
          return false;
        }
      }
      stamp
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(at.toIso8601String());
    } on FileSystemException {
      // A home without write access: no line rather than one every time.
      return false;
    }
    console
      ..writeln()
      ..writeln(console.style(nudgeFor(at), dim: true))
      ..writeln(console.style(hideHint, dim: true));
    return true;
  }

  /// How to turn the lines off, under each of them (Blueprint #137 §3.4).
  static const String hideHint = '(hide this with: dartisan sponsor --hide)';

  /// The fixed lines under the next steps of `dartisan new` (no quota), or
  /// null when [silenced].
  String? get newProjectLine => silenced
      ? null
      : '${console.style('Daravel is kept going by its sponsors: $sponsorUrl', dim: true)}\n'
            '${console.style(hideHint, dim: true)}';
}
