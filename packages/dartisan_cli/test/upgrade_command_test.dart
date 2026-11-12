import 'dart:async';
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
    // What pub.dev has, as package@version; null: every one asked for.
    Set<String>? onPubDev;
    Object? pubDevError;
    var pubUpgradeExit = 0;
    late List<String> asked;
    // A pub.dev that never answers.
    var hang = false;
    // Requests in flight at once, and the most seen.
    var inFlight = 0;
    var peak = 0;

    Future<int> run(
      List<String> args, {
      Duration checkDeadline = const Duration(seconds: 30),
    }) {
      final runner = CommandRunner<int>('dartisan', 'test')
        ..addCommand(
          UpgradeCommand(
            latest: () async => '1.9.0',
            dart: (args, {workingDirectory}) async {
              calls.add((args, workingDirectory));
              return args.join(' ') == 'pub upgrade' ? pubUpgradeExit : 0;
            },
            published: (package, version) async {
              asked.add('$package@$version');
              inFlight++;
              peak = inFlight > peak ? inFlight : peak;
              try {
                if (hang) {
                  await Completer<void>().future;
                }
                await Future<void>.delayed(const Duration(milliseconds: 5));
                if (pubDevError case final error?) {
                  throw error;
                }
                return onPubDev?.contains('$package@$version') ?? true;
              } finally {
                inFlight--;
              }
            },
            checkDeadline: checkDeadline,
          ),
        );
      return IOOverrides.runZoned(
        () async => await runner.run(args) ?? 0,
        getCurrentDirectory: () => project,
      );
    }

    setUp(() {
      calls = [];
      asked = [];
      onPubDev = null;
      pubDevError = null;
      pubUpgradeExit = 0;
      hang = false;
      inFlight = 0;
      peak = 0;
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

    String pubspec() =>
        File(p.join(project.path, 'pubspec.yaml')).readAsStringSync();
    String lock() =>
        File(p.join(project.path, 'pubspec.lock')).readAsStringSync();

    test('asks pub.dev for every package it moves, and the CLI', () async {
      expect(await run(['upgrade']), 0);
      // daravel_lints comes from git: not moved, not asked.
      expect(asked.toSet(), {
        'daravel@1.9.0',
        'daravel_mysql@1.9.0',
        'daravel_test@1.9.0',
        'dartisan_cli@1.9.0',
      });
    });

    test('a package not on pub.dev at the target yet changes nothing '
        '(a release half published, as 1.27.1 was for an hour)', () async {
      onPubDev = {'daravel@1.9.0', 'daravel_test@1.9.0', 'dartisan_cli@1.9.0'};
      expect(await run(['upgrade']), 1);
      expect(pubspec(), _pubspec);
      expect(calls, isEmpty, reason: 'no pub upgrade, no global activate');
    });

    test('pub.dev out of reach changes nothing', () async {
      pubDevError = const SocketException('offline');
      expect(await run(['upgrade']), 1);
      expect(pubspec(), _pubspec);
      expect(calls, isEmpty);
    });

    test('a failing pub upgrade puts pubspec.yaml and pubspec.lock back, '
        'and the CLI is not activated', () async {
      final lockBefore = lock();
      pubUpgradeExit = 65;
      expect(await run(['upgrade']), 65);
      expect(pubspec(), _pubspec);
      expect(lock(), lockBefore);
      expect(calls.map((c) => c.$1.join(' ')), ['pub upgrade']);
    });

    test('--no-global does not ask for dartisan_cli', () async {
      onPubDev = {'daravel@1.9.0', 'daravel_mysql@1.9.0', 'daravel_test@1.9.0'};
      expect(await run(['upgrade', '--no-global']), 0);
      expect(asked, isNot(contains('dartisan_cli@1.9.0')));
      expect(pubspec(), contains('  daravel: ^1.9.0'));
    });

    test('a pub.dev that never answers ends at the deadline, nothing '
        'changed', () async {
      hang = true;
      final watch = Stopwatch()..start();
      expect(
        await run([
          'upgrade',
        ], checkDeadline: const Duration(milliseconds: 200)),
        1,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(pubspec(), _pubspec);
      expect(calls, isEmpty);
    });

    test('every Daravel package is asked for, at most 8 at once', () async {
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(
        'name: shop\n'
        'environment:\n  sdk: ^3.13.0\n\n'
        'dependencies:\n'
        '${[for (final name in daravelPackages) '  $name: ^1.7.0'].join('\n')}\n',
      );
      expect(await run(['upgrade']), 0);
      expect(asked.toSet(), {
        for (final name in daravelPackages) '$name@1.9.0',
      });
      expect(peak, inInclusiveRange(1, UpgradeCommand.checkBatch));
      expect(
        daravelPackages.length,
        greaterThan(UpgradeCommand.checkBatch),
        reason: 'the batching is exercised',
      );
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
