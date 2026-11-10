import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// A project's own command, listed last as `project`.
final class ReportCommand extends Command<int> {
  ReportCommand(AppFactory _);

  @override
  String get name => 'reports:send';

  @override
  String get description => 'Send the weekly reports.';

  @override
  Future<int> run() async => 0;
}

Application _noApp() => throw UnimplementedError('not booted by list');

/// `dart test test/list_test.dart` with `UPDATE_GOLDENS=1` rewrites it.
final File golden = File('test/goldens/list_no_color.txt');

void main() {
  (DartisanRunner, StringBuffer) runner({
    bool terminal = false,
    bool color = false,
    bool unicode = false,
  }) {
    final out = StringBuffer();
    return (
      DartisanRunner(
        _noApp,
        commands: [ReportCommand.new],
        console: Console(
          out: out,
          err: out,
          color: color,
          unicode: unicode,
          terminal: terminal,
          width: 80,
        ),
      ),
      out,
    );
  }

  test('list --no-color: the commands grouped, as the golden file', () async {
    final (cli, out) = runner();
    expect(await cli.run(['list', '--no-color']), 0);
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync('$out');
    }
    expect('$out', golden.readAsStringSync().replaceAll('\r\n', '\n'));
    final text = '$out';
    expect(text, isNot(contains('\x1B[')));
    expect(text.indexOf('\n about '), lessThan(text.indexOf('\n cache\n')));
    expect(text.indexOf('\n queue\n'), lessThan(text.indexOf('\n project\n')));
    expect(text, contains(' project\n  reports:send'));
  });

  test('off a terminal, dartisan prints the plain usage of package:args, '
      'without a banner', () async {
    final (cli, out) = runner();
    expect(await cli.run([]), isNull);
    expect('$out', startsWith('Daravel command-line interface.\n\nUsage:'));
    expect('$out', isNot(contains('sponsors')));
  });

  test('on a terminal: the banner, then the grouped commands', () async {
    final (cli, out) = runner(terminal: true, unicode: true);
    await cli.run([]);
    final text = '$out';
    expect(text, contains('Daravel $daravelVersion · Dart '));
    expect(text, contains('Made with the help of our sponsors ♥ $sponsorUrl'));
    expect(text, contains('Available commands:'));
    expect(text, contains(' make\n'));
    expect(text, isNot(contains('\x1B[')), reason: 'no colour asked');
  });

  test(
    'colours when the console colours: names green, groups yellow',
    () async {
      final (cli, out) = runner(terminal: true, color: true);
      await cli.run(['list']);
      expect('$out', contains('\x1B[32mabout'));
      expect('$out', contains(' \x1B[33mmake\x1B[0m'));
    },
  );

  test('list --raw and --format=json', () async {
    var (cli, out) = runner();
    await cli.run(['list', '--raw']);
    final names = '$out'.trim().split('\n');
    expect(names, containsAll(['about', 'make:model', 'reports:send']));
    expect(names.every((n) => !n.contains(' ')), isTrue);
    (cli, out) = runner();
    await cli.run(['list', '--format=json']);
    final json = (jsonDecode('$out') as List<Object?>)
        .cast<Map<String, Object?>>();
    Map<String, Object?> entry(String name) =>
        json.singleWhere((e) => e['name'] == name);
    expect(entry('make:model')['group'], 'make');
    expect(entry('about')['group'], '');
    expect(entry('reports:send'), {
      'name': 'reports:send',
      'description': 'Send the weekly reports.',
      'group': 'project',
    });
  });

  test(
    'help <command>: unchanged without colour, option names green with',
    () async {
      Future<String> help(bool color) async {
        final printed = StringBuffer();
        final (cli, _) = runner(color: color);
        await runZoned(
          () => cli.run(['help', 'list']),
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => printed.writeln(line),
          ),
        );
        return '$printed';
      }

      final plain = await help(false);
      expect(plain, contains('    --raw'));
      expect(plain, isNot(contains('\x1B[')));
      final coloured = await help(true);
      expect(coloured, contains('\x1B[32m--raw\x1B[0m'));
      expect(
        coloured.replaceAll(RegExp('\x1B\\[[0-9;]*m'), ''),
        plain,
        reason: 'only colour is added',
      );
    },
  );

  test('--no-color and --ansi are global and may follow the command', () async {
    final (cli, out) = runner();
    expect(await cli.run(['--no-color', 'list', '--raw']), 0);
    expect(await cli.run(['list', '--raw', '--ansi']), 0);
    expect('$out', contains('make:model'));
  });

  test('the global dartisan lists its commands too', () async {
    final out = StringBuffer();
    final cli = GlobalDartisanRunner(
      console: Console(out: out, color: false, terminal: false),
    );
    await cli.run(['list', '--raw']);
    expect('$out'.trim().split('\n'), containsAll(['new', 'list', 'upgrade']));
  });
}
