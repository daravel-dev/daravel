import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// A project command that ends with [code], celebrating when asked.
final class HappyCommand extends Command<int> {
  HappyCommand(this.code, {this.celebrates = false, this.label = 'happy'});

  final int code;
  final bool celebrates;
  final String label;

  @override
  String get name => label;

  @override
  String get description => 'Test.';

  @override
  Future<int> run() async {
    if (runner case final DartisanConsole cli when celebrates) {
      cli.celebrate();
    }
    return code;
  }
}

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('dartisan_nudge_'));
  tearDown(() => home.deleteSync(recursive: true));

  Nudges nudges(
    StringBuffer out, {
    Map<String, String> env = const {},
    bool terminal = true,
    required DateTime Function() now,
  }) => Nudges(
    Console(out: out, color: false, terminal: terminal),
    environment: env,
    config: DartisanUserConfig(home: home.path),
    now: now,
  );

  test('the line of the day: the same all day, another the next day', () {
    final morning = DateTime(2026, 11, 6, 8);
    expect(nudgeFor(morning), nudgeFor(DateTime(2026, 11, 6, 23)));
    expect({
      for (var d = 0; d < 3; d++) nudgeFor(morning.add(Duration(days: d))),
    }, hasLength(3));
  });

  test('the lines thank or inform: no please, donate or amounts', () {
    for (final line in nudgeLines) {
      expect(line.toLowerCase(), isNot(contains('please')));
      expect(line.toLowerCase(), isNot(contains('donate')));
      expect(line, isNot(matches(RegExp(r'[$€£]|\bRp|\d'))));
      expect(line, contains(sponsorUrl));
    }
  });

  test('silent in CI, off a terminal, with DARTISAN_NO_NUDGE=1 or after '
      'sponsor --hide', () {
    final out = StringBuffer();
    DateTime now() => DateTime(2026, 11, 6);
    for (final name in ciVariables) {
      expect(
        nudges(out, env: {name: 'true'}, now: now).afterSuccess(),
        isFalse,
      );
    }
    expect(
      nudges(out, env: {'DARTISAN_NO_NUDGE': '1'}, now: now).afterSuccess(),
      isFalse,
    );
    expect(nudges(out, terminal: false, now: now).afterSuccess(), isFalse);
    DartisanUserConfig(home: home.path).setNudge(false);
    expect(nudges(out, now: now).afterSuccess(), isFalse);
    expect(nudges(out, now: now).newProjectLine, isNull);
    expect('$out', isEmpty);
  });

  test('at most once in 24 hours per machine', () {
    final out = StringBuffer();
    var now = DateTime(2026, 11, 6, 9);
    final lines = nudges(out, now: () => now);
    expect(lines.afterSuccess(), isTrue);
    expect('$out', contains(nudgeFor(now)));
    now = now.add(const Duration(hours: 23));
    expect(lines.afterSuccess(), isFalse);
    now = now.add(const Duration(hours: 2));
    expect(lines.afterSuccess(), isTrue);
    expect(File('${home.path}/.dartisan/last_nudge').existsSync(), isTrue);
  });

  test('new has its fixed line, without the quota', () {
    final out = StringBuffer();
    final lines = nudges(out, now: () => DateTime(2026, 11, 6));
    expect(lines.newProjectLine, contains(sponsorUrl));
    lines.afterSuccess();
    expect(lines.newProjectLine, isNotNull);
  });

  group('the runner', () {
    Future<int> run(Command<int> command, List<int> calls) async {
      final runner = DartisanRunner(
        () => Application.configure(basePath: home.path).create(),
        commands: [(_) => command],
        console: Console(out: StringBuffer(), color: false, terminal: true),
        nudges: (console) {
          calls.add(1);
          return Nudges(
            console,
            environment: const <String, String>{},
            config: DartisanUserConfig(home: home.path),
          );
        },
      );
      return await runner.run([command.name]) ?? 0;
    }

    test('asks after a success that celebrates, never after a failure or '
        'an ordinary command', () async {
      final calls = <int>[];
      expect(await run(HappyCommand(0, celebrates: true), calls), 0);
      expect(calls, hasLength(1));
      expect(await run(HappyCommand(1, celebrates: true), calls), 1);
      expect(calls, hasLength(1), reason: 'exit 1');
      expect(await run(HappyCommand(0), calls), 0);
      expect(calls, hasLength(1), reason: 'not a happy moment');
    });
  });
}
