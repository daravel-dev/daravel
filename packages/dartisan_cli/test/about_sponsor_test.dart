import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('dartisan_home_'));
  tearDown(() => home.deleteSync(recursive: true));

  test(
    'about --json: the application, Daravel and Community sections',
    () async {
      // ignore: close_sinks (stdout of the zone, never opened)
      final out = _Capture();
      final code = await IOOverrides.runZoned(
        () => DartisanRunner(
          () =>
              Application.configure(basePath: home.path)
                  .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
                  .create(),
        ).execute(['about', '--json']),
        stdout: () => out,
      );
      expect(code, 0);
      final json = jsonDecode('${out.buffer}') as Map<String, Object?>;
      expect((json['application']! as Map)['Environment'], 'testing');
      final daravel = json['daravel']! as Map;
      expect(daravel['Version'], daravelVersion);
      expect(daravel['Mode'], 'JIT');
      expect(daravel.keys, containsAll(['Dart SDK', 'OS', 'Architecture']));
      expect(
        (json['community']! as Map)['Sponsor'],
        'https://github.com/sponsors/daravel-dev',
      );
    },
  );

  (CommandRunner<int>, StringBuffer, List<List<String>>) sponsor() {
    final out = StringBuffer();
    final started = <List<String>>[];
    final runner = CommandRunner<int>('dartisan', '')
      ..addCommand(
        SponsorCommand(
          console: () =>
              Console(out: out, color: false, unicode: false, width: 80),
          config: DartisanUserConfig(home: home.path),
          start: (program, args) async {
            started.add([program, ...args]);
            throw const ProcessException('none', []);
          },
        ),
      );
    return (runner, out, started);
  }

  test('sponsor: a box with the one link', () async {
    final (cli, out, _) = sponsor();
    await cli.run(['sponsor']);
    expect('$out', contains('https://github.com/sponsors/daravel-dev'));
    expect('$out', startsWith('+- Sponsor Daravel '));
  });

  test(
    'sponsor --hide is kept in ~/.dartisan/config.json; --show undoes it',
    () async {
      final (cli, out, _) = sponsor();
      await cli.run(['sponsor', '--status']);
      expect('$out', contains('shown'));
      await cli.run(['sponsor', '--hide']);
      final file = File('${home.path}/.dartisan/config.json');
      expect(jsonDecode(file.readAsStringSync()), {'nudge': false});
      expect(DartisanUserConfig(home: home.path).nudge, isFalse);
      out.clear();
      await cli.run(['sponsor', '--status']);
      expect('$out', contains('hidden'));
      await cli.run(['sponsor', '--show']);
      expect(DartisanUserConfig(home: home.path).nudge, isTrue);
    },
  );

  test('a broken config file reads as the defaults', () {
    File('${home.path}/.dartisan/config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(DartisanUserConfig(home: home.path).nudge, isTrue);
  });

  test('sponsor --open starts the browser, or prints the link', () async {
    final (cli, out, started) = sponsor();
    await cli.run(['sponsor', '--open']);
    expect(started.single.last, 'https://github.com/sponsors/daravel-dev');
    expect('$out'.trim(), 'https://github.com/sponsors/daravel-dev');
  });

  test('both runners have sponsor', () {
    final console = Console(out: StringBuffer(), color: false, terminal: false);
    expect(
      DartisanRunner(
        () => throw UnimplementedError(),
        console: console,
      ).commands.containsKey('sponsor'),
      isTrue,
    );
    expect(
      GlobalDartisanRunner(console: console).commands.containsKey('sponsor'),
      isTrue,
    );
  });
}

/// Collects what a command prints.
final class _Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
