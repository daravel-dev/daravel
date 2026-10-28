import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Answers the questions `pub:add` asks.
final class FakePrompter implements Prompter {
  FakePrompter({
    this.interactive = true,
    this.picks = const [],
    this.yes = false,
  });

  @override
  final bool interactive;
  final List<int> picks;
  final bool yes;
  final List<String> asked = [];

  @override
  Future<List<int>> pick(
    String title,
    List<String> options, {
    bool many = false,
  }) async {
    asked.add(title);
    return picks;
  }

  @override
  Future<bool> confirm(String question) async {
    asked.add(question);
    return yes;
  }
}

/// Collects what a command prints.
final class Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('helpers', () {
    test('installed packages, hosted, path and git', () {
      const pubspec = '''
name: shop
dependencies:
  daravel: ^1.14.0
  daravel_permission:
    path: ../daravel_permission
  uuid: any
dev_dependencies:
  daravel_test: ^1.14.0
  daravel_lints:
    git:
      url: https://github.com/daravel-dev/daravel
dependency_overrides:
  daravel_s3: ^1.0.0
''';
      expect(installedPackages(pubspec), {
        'daravel': '^1.14.0',
        'daravel_permission': 'path',
        'uuid': 'any',
        'daravel_test': '^1.14.0',
        'daravel_lints': 'git',
      });
      const local =
          'name: x\ndependencies:\n  daravel:\n    path: ../repo/packages/daravel\n';
      expect(daravelPath(local), '../repo/packages/daravel');
      expect(daravelPath(pubspec), isNull);
      expect(
        addPathDependency(local, 'daravel_s3', daravelPath(local)!),
        contains('  daravel_s3:\n    path: ../repo/packages/daravel_s3\n'),
      );
      expect(
        addDevDependency('name: x\n', 'daravel_test', '^1.0.0'),
        'name: x\n\ndev_dependencies:\n  daravel_test: ^1.0.0\n',
      );
    });

    test('numbered picks', () {
      expect(parsePicks('2', 3), [1]);
      expect(parsePicks('1, 3', 3, many: true), [0, 2]);
      expect(parsePicks('1,3', 3), isEmpty, reason: 'one only');
      expect(parsePicks('4', 3), isEmpty);
      expect(parsePicks('x', 3), isEmpty);
      expect(parsePicks('', 3), isEmpty);
    });

    test('the interactive selector: filter, move, tick, confirm, quit', () {
      final state = SelectorState([
        'daravel_s3 storage',
        'daravel_permission roles',
        'daravel_google calendar',
      ]);
      for (final c in 'ro'.codeUnits) {
        state.type(c);
      }
      expect(state.visible, [1], reason: '"ro" is in "roles" only');
      state
        ..type(0x08)
        ..type(0x08);
      expect(state.visible, [0, 1, 2]);
      state
        ..key(SelectorKey.down)
        ..type(0x20)
        ..key(SelectorKey.down)
        ..type(0x20)
        ..key(SelectorKey.up)
        ..type(0x20)
        ..type(0x0D);
      expect(state.done, isTrue);
      expect(state.result, [2]);
      final quit = SelectorState(['a'])..type(0x71);
      expect(quit.result, isEmpty);
      final single = SelectorState(['a', 'b'], many: false)
        ..key(SelectorKey.down)
        ..type(0x0D);
      expect(single.result, [1]);
      expect(single.render('T').any((l) => l.contains('[ ]')), isFalse);
    });
  });

  group('commands in a project', () {
    late Directory project;
    late List<List<String>> dartCalls;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('pub_add_');
      final files = newProjectFiles(
        package: 'shop',
        appName: 'Shop',
        source: const PubHostedSource(),
        appKey: 'base64:test',
      );
      for (final path in [
        'pubspec.yaml',
        'bootstrap/app.dart',
        'bootstrap/migrations.dart',
        'bootstrap/commands.dart',
        '.env.example',
      ]) {
        File(p.join(project.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(files[path]!);
      }
      dartCalls = [];
    });

    tearDown(() async {
      await project.delete(recursive: true);
    });

    String read(String path) =>
        File(p.join(project.path, path)).readAsStringSync();

    Future<(int?, String)> dartisan(
      List<String> args, {
      Prompter? prompter,
      PubDevSearch? pubDev,
    }) async {
      // ignore: close_sinks (stdout of the zone, never opened)
      final out = Capture();
      final runner = CommandRunner<int>('dartisan', 'test')
        ..addCommand(DbInstallCommand())
        ..addCommand(RedisInstallCommand())
        ..addCommand(PubListCommand())
        ..addCommand(PubSearchCommand(pubDev: pubDev))
        ..addCommand(
          PubAddCommand(
            prompter: prompter ?? FakePrompter(interactive: false),
            dart: (arguments, {workingDirectory}) async {
              dartCalls.add(arguments);
              return 0;
            },
          ),
        );
      final code = await IOOverrides.runZoned(
        () => runner.run(args),
        // The project is the cwd of this zone only: the process cwd is
        // shared with the other test files, which run at the same time.
        getCurrentDirectory: () => project,
        stdout: () => out,
        stderr: () => out,
      );
      return (code, out.buffer.toString());
    }

    test('pub:add wires a package in, once', () async {
      final (code, output) = await dartisan(['pub:add', 'rbac']);
      expect(code, 0);
      expect(
        read('pubspec.yaml'),
        contains('  daravel_permission: ^$daravelVersion'),
      );
      final app = read('bootstrap/app.dart');
      expect(app, contains('.withPermissions()'));
      expect(
        app,
        contains(
          "import 'package:daravel_permission/daravel_permission.dart';",
        ),
      );
      final migrations = read('bootstrap/migrations.dart');
      expect(migrations, contains('const CreatePermissionTables(),'));
      expect(
        migrations,
        contains(
          "import 'package:daravel_permission/daravel_permission.dart';",
        ),
      );
      final commands = read('bootstrap/commands.dart');
      expect(commands, contains('...permissionCommands,'));
      expect(
        commands,
        contains("import 'package:daravel_permission/commands.dart';"),
      );
      expect(
        read('.env.example'),
        contains(
          '# Roles and permissions (dartisan pub:add permission)\n# PERMISSION_GUARD=web',
        ),
      );
      expect(output, contains('dartisan migrate'));
      expect(dartCalls, [
        ['pub', 'get'],
        [
          'format',
          'bootstrap/app.dart',
          'bootstrap/migrations.dart',
          'bootstrap/commands.dart',
        ],
      ]);

      final files = [
        'pubspec.yaml',
        'bootstrap/app.dart',
        'bootstrap/migrations.dart',
        'bootstrap/commands.dart',
        '.env.example',
      ];
      final snapshot = [for (final f in files) read(f)];
      dartCalls.clear();
      final (again, said) = await dartisan(['install', 'permission']);
      expect(again, 0);
      expect(said, contains('daravel_permission is already installed'));
      expect([for (final f in files) read(f)], snapshot);
      expect(dartCalls, isEmpty);
    });

    test('several packages, no secrets filled in, delegated drivers', () async {
      final (code, _) = await dartisan([
        'pub:add',
        's3',
        'livekit',
        'audit',
        'postgres',
        'test',
        '--no-get',
      ]);
      expect(code, 0);
      final pubspec = read('pubspec.yaml');
      for (final package in [
        'daravel_s3',
        'daravel_livekit',
        'daravel_activitylog',
        'daravel_postgres',
      ]) {
        expect(pubspec, contains('  $package: ^$daravelVersion'));
      }
      expect(installedPackages(pubspec)['daravel_test'], isNotNull);
      final app = read('bootstrap/app.dart');
      for (final call in [
        '.withS3()',
        '.withLivekit()',
        '.withActivityLog()',
        '.withPostgres()',
      ]) {
        expect(app, contains(call));
      }
      final env = read('.env.example');
      expect(env, contains('# LIVEKIT_API_SECRET=\n'));
      expect(env, isNot(contains('LIVEKIT_API_SECRET=secret')));
      expect(
        read('bootstrap/migrations.dart'),
        contains('const CreateActivityLogTable(),'),
      );
      expect(dartCalls, isEmpty, reason: '--no-get');
    });

    test('ambiguous, unknown and pub.dev names', () async {
      final (ambiguous, said) = await dartisan(['pub:add', 'cloud', '--yes']);
      expect(ambiguous, 64);
      expect(said, contains('daravel_s3 and daravel_google'));

      final picking = FakePrompter(picks: [1]);
      expect(
        (await dartisan([
          'pub:add',
          'cloud',
          '--no-get',
        ], prompter: picking)).$1,
        0,
      );
      expect(read('pubspec.yaml'), contains('daravel_google'));

      final (typo, hint) = await dartisan(['pub:add', 'daravel_permision']);
      expect(typo, 64);
      expect(hint, contains('Did you mean permission'));

      final (skipped, note) = await dartisan(['pub:add', 'pdf']);
      expect(skipped, 0);
      expect(note, contains('Skipped pdf'));
      expect(dartCalls, isEmpty);

      final declined = FakePrompter();
      await dartisan(['pub:add', 'pdf'], prompter: declined);
      expect(declined.asked.single, contains("'pdf' is not a Daravel package"));
      expect(dartCalls, isEmpty);

      expect((await dartisan(['pub:add', 'pdf', '--yes'])).$1, 0);
      expect(dartCalls, [
        ['pub', 'add', 'pdf'],
      ]);
    });

    test('no names: a menu in a terminal, an error without one', () async {
      await expectLater(dartisan(['pub:add']), throwsA(isA<UsageException>()));
      final menu = FakePrompter(picks: [0]);
      expect((await dartisan(['pub:add', '--no-get'], prompter: menu)).$1, 0);
      expect(menu.asked.single, 'Daravel packages');
      expect(
        read('pubspec.yaml'),
        contains('daravel_sqlite'),
        reason: 'the first one not installed',
      );
    });

    test('pub:list and pub:search', () async {
      await dartisan(['pub:add', 'teorion', '--no-get']);
      final (_, json) = await dartisan(['pub:list', '--json']);
      final list = (jsonDecode(json) as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(
        list.firstWhere((m) => m['package'] == 'daravel_teorion')['installed'],
        '^$daravelVersion',
      );
      expect(
        list.firstWhere((m) => m['package'] == 'daravel_s3')['installed'],
        isNull,
      );
      final (_, table) = await dartisan(['pub:list']);
      expect(table, contains('daravel_teorion'));
      expect(table, contains('installed (^$daravelVersion)'));

      final (_, found) = await dartisan(['pub:search', 'bucket']);
      expect(found, contains('daravel_s3 (available)'));
      final (_, online) = await dartisan(
        ['pub:search', 'pdf', '--online'],
        pubDev: (query) async => [
          (name: 'pdf', version: '3.11.1', description: 'PDF for Dart'),
        ],
      );
      expect(online, contains("none match 'pdf'"));
      expect(online, contains('pdf 3.11.1: PDF for Dart'));
    });
  });

  test(
    'a new project with packages added analyzes, runs and exits (e2e)',
    () async {
      final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
      final root = await Directory.systemTemp.createTemp('pub_add_e2e_');
      addTearDown(() => root.delete(recursive: true));
      final target = p.join(root.path, 'shop');
      expect(
        await GlobalDartisanRunner().execute(['new', target, '--path=$repo']),
        0,
      );
      Future<ProcessResult> run(List<String> args) =>
          Process.run(dartExecutable(), args, workingDirectory: target);
      final add = await run([
        'run',
        'bin/dartisan.dart',
        'pub:add',
        'rbac',
        'activitylog',
        's3',
        'livekit',
        'teobiefy',
        'google',
        'teorion',
      ]);
      expect(add.exitCode, 0, reason: '${add.stdout}${add.stderr}');
      final analyze = await run(['analyze', '--fatal-infos']);
      expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
      // The packages' commands run and the process ends: a package that
      // subscribes at boot must not keep the isolate alive at shutdown.
      for (final command in [
        ['migrate'],
        ['permission:create-role', 'editor'],
        ['activitylog:clean'],
      ]) {
        final process = await Process.start(
          dartExecutable(),
          ['run', 'bin/dartisan.dart', ...command],
          workingDirectory: target,
          environment: {'APP_ENV': 'local'},
        );
        final code = await process.exitCode.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        expect(code, 0, reason: '${command.join(' ')} exits');
      }
      final test = await run(['test']);
      expect(test.exitCode, 0, reason: '${test.stdout}');
    },
    skip: Platform.environment['DARAVEL_E2E'] == '1'
        ? false
        : 'set DARAVEL_E2E=1 to run (pub get, analyze, commands, ~3 min)',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
