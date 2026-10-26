import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _pubspec = '''
name: shop
environment:
  sdk: ^3.13.0

dependencies:
  daravel: ^1.7.0
  daravel_mysql:
    version: ">=1.7.0 <2.0.0"
  http: ^1.2.0

dev_dependencies:
  daravel_test: ^1.7.0
  daravel_lints:
    git:
      url: https://github.com/daravel-dev/daravel.git
      path: packages/daravel_lints
  test: ^1.25.0

dependency_overrides:
  daravel:
    path: ../daravel/packages/daravel
''';

void main() {
  group('rewriteConstraints', () {
    test('sets hosted Daravel packages to ^version, and only those', () {
      final result = rewriteConstraints(_pubspec, '1.9.0');
      expect(result.updated, ['daravel', 'daravel_mysql', 'daravel_test']);
      expect(result.local, ['daravel_lints']);
      expect(result.pubspec, contains('  daravel: ^1.9.0\n'));
      expect(result.pubspec, contains('    version: ^1.9.0\n'));
      expect(result.pubspec, contains('  daravel_test: ^1.9.0\n'));
      expect(result.pubspec, contains('  http: ^1.2.0\n'));
      expect(result.pubspec, contains('  test: ^1.25.0\n'));
      // git and overrides are untouched.
      expect(result.pubspec, contains('      path: packages/daravel_lints\n'));
      expect(
        result.pubspec,
        endsWith(
          'dependency_overrides:\n  daravel:\n'
          '    path: ../daravel/packages/daravel\n',
        ),
      );
    });

    test('leaves a pubspec without Daravel packages as it is', () {
      const plain = 'name: x\ndependencies:\n  http: ^1.2.0\n';
      final result = rewriteConstraints(plain, '1.9.0');
      expect(result.updated, isEmpty);
      expect(result.pubspec, plain);
    });
  });

  test('lockedVersion reads daravel from pubspec.lock', () {
    const lock = '''
packages:
  args:
    dependency: transitive
    description:
      name: args
    source: hosted
    version: "2.7.0"
  daravel:
    dependency: "direct main"
    description:
      name: daravel
      sha256: abc
      url: "https://pub.dev"
    source: hosted
    version: "1.8.1"
''';
    expect(lockedVersion(lock), '1.8.1');
    expect(lockedVersion('packages:\n'), isNull);
  });

  group('upgrade', () {
    late Directory project;
    late List<(List<String>, String?)> calls;

    Future<int> run(List<String> args) {
      final runner = CommandRunner<int>('dartisan', 'test')
        ..addCommand(
          UpgradeCommand(
            latest: () async => '1.9.0',
            dart: (args, {workingDirectory}) async {
              calls.add((args, workingDirectory));
              return 0;
            },
          ),
        );
      return IOOverrides.runZoned(
        () async => await runner.run(args) ?? 0,
        getCurrentDirectory: () => project,
      );
    }

    setUp(() {
      calls = [];
      project = Directory.systemTemp.createTempSync('upgrade_test');
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(_pubspec);
      File(p.join(project.path, 'pubspec.lock')).writeAsStringSync(
        'packages:\n  daravel:\n    source: hosted\n    version: "1.7.0"\n',
      );
      Directory(p.join(project.path, 'bootstrap')).createSync();
      File(p.join(project.path, 'bootstrap', 'app.dart'))
          .writeAsStringSync('// app');
    });

    tearDown(() => project.deleteSync(recursive: true));

    test('--check changes nothing', () async {
      expect(await run(['upgrade', '--check']), 0);
      expect(
        File(p.join(project.path, 'pubspec.yaml')).readAsStringSync(),
        _pubspec,
      );
      expect(calls, isEmpty);
    });

    test(
      'rewrites pubspec.yaml, runs pub upgrade, activates the CLI',
      () async {
        expect(await run(['upgrade']), 0);
        expect(
          File(p.join(project.path, 'pubspec.yaml')).readAsStringSync(),
          contains('  daravel: ^1.9.0'),
        );
        expect(calls.map((c) => c.$1.join(' ')), [
          'pub upgrade',
          'pub global activate dartisan_cli 1.9.0',
        ]);
        expect(p.canonicalize(calls.first.$2!), p.canonicalize(project.path));
      },
    );

    test('--to, --no-get and --no-global', () async {
      expect(
        await run(['upgrade', '--to=1.8.1', '--no-get', '--no-global']),
        0,
      );
      expect(
        File(p.join(project.path, 'pubspec.yaml')).readAsStringSync(),
        contains('  daravel: ^1.8.1'),
      );
      expect(calls, isEmpty);
      expect(await run(['upgrade', '--to=latest']), 64);
    });
  });

  test('upgrade and self-update are not delegated to the project CLI', () {
    bool delegates(List<String> args) =>
        GlobalDartisanRunner.delegates(args, inProject: true);
    expect(delegates(['upgrade']), isFalse);
    expect(delegates(['self-update']), isFalse);
    expect(delegates(['help', 'upgrade']), isFalse);
    expect(delegates(['new', 'blog']), isFalse);
    expect(delegates(['migrate']), isTrue);
    expect(delegates([]), isTrue);
  });
}
