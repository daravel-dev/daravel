import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class CreateNotes extends Migration {
  const CreateNotes();

  @override
  String get name => '2026_01_01_000000_create_notes';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('notes', (t) {
    t.id();
    t.string('text');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('notes');
}

final class NoteSeeder extends Seeder {
  const NoteSeeder();

  @override
  Future<void> run() => DB.table('notes').insert({'text': 'seeded'});
}

/// A project's own command, with an alias; records each run.
final class ProbeCommand extends Command<int> {
  ProbeCommand() {
    argParser.addFlag('loud', negatable: false);
  }

  static final List<List<String>> runs = [];

  @override
  String get name => 'probe';

  @override
  List<String> get aliases => const ['probe-alias'];

  @override
  String get description => 'Records that it ran.';

  @override
  Future<int> run() async {
    runs.add([name, ...argResults!.arguments]);
    return 0;
  }
}

/// `run_command` decides on the command dartisan's own parser reads, offers
/// a fixed list (more with `mcp:serve --allow-command`), and refuses the
/// rest: global flags in front, `--`, aliases and `migrate --seed` cannot
/// reach a command it would refuse by name.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp_run_command');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
    ProbeCommand.runs.clear();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Application project({String env = 'production'}) =>
      Application.configure(basePath: root.path)
          .withEnv({
            'APP_ENV': env,
            'APP_KEY': 'base64:${'A' * 43}=',
            'DB_DATABASE': p.join(root.path, 'database.sqlite'),
          })
          .withLogLevel(LogLevel.critical)
          .withMigrations(const [CreateNotes()])
          .withSeeders(const [NoteSeeder()])
          .create();

  DartisanRunner runnerFor(String env) => DartisanRunner(
    () => project(env: env),
    commands: [(_) => ProbeCommand()],
  );

  /// The command line `run_command` handed on.
  final List<List<String>> handed = [];

  Future<McpServer> server({
    String env = 'production',
    bool withRunner = true,
    Set<String> allowed = const {},
    bool execute = false,
  }) async {
    final app = project(env: env);
    await app.boot();
    addTearDown(app.shutdown);
    final runner = runnerFor(env);
    return McpServer(
      app,
      allowWrite: true,
      runner: withRunner ? runner : null,
      allowedCommands: allowed,
      runCommand: (command, arguments) async {
        handed.add([command, ...arguments]);
        if (!execute) {
          return (exitCode: 0, stdout: '', stderr: '');
        }
        // What the child process does with the same command line.
        final code = await IOOverrides.runZoned(
          () => runnerFor(env).execute([command, ...arguments]),
          getCurrentDirectory: () => root,
        );
        return (exitCode: code, stdout: '', stderr: '');
      },
    );
  }

  Future<Object?> run(McpServer s, String command, [List<String>? args]) =>
      s.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'run_command',
          'arguments': {'command': command, 'arguments': ?args},
        },
      });

  /// Whether the call came back as a refusal (a tool error) and handed
  /// nothing on.
  Future<bool> refused(
    McpServer s,
    String command, [
    List<String>? args,
  ]) async {
    final before = handed.length;
    final response = (await run(s, command, args))! as Map<String, Object?>;
    final result = response['result'] as Map<String, Object?>?;
    final error = response['error'] != null || result?['isError'] == true;
    return error && handed.length == before;
  }

  setUp(handed.clear);

  // Each form an earlier version let through, or a neighbour of one.
  final production = <(String, List<String>)>[
    ('--no-color', ['migrate:fresh', '--force']),
    ('--ansi', ['migrate:fresh', '--force']),
    ('--no-color', ['tinker', 'File("x").writeAsStringSync("1")']),
    ('--ansi', ['env:decrypt', '--force']),
    ('-V', ['migrate:fresh']),
    ('--', ['migrate:fresh', '--force']),
    ('migrate', ['--seed', '--force']),
    ('migrate', ['--force', '--seed']),
    ('db:restore', ['backup.sql', '--force']),
    ('db:seed', ['--force']),
    ('migrate:fresh', ['--force']),
    ('queue:clear', ['--force']),
    ('cache:clear', []),
    ('down', []),
    ('tinker', []),
    ('serve', []),
    ('db:transfer', []),
    ('pub:add', ['http']),
    ('self-update', []),
    ('test', []),
    ('route:diff', ['--laravel=../laravel-app']),
    ('security:audit', ['--target=http://192.168.0.1']),
    ('probe', []),
    ('probe-alias', []),
    ('migrate', ['--no-such-option']),
    ('no:such-command', []),
  ];

  for (final (command, args) in production) {
    test('production: "$command ${args.join(' ')}" is refused', () async {
      expect(await refused(await server(), command, args), isTrue);
    });
  }

  test('production: offered commands are handed on as given', () async {
    final s = await server();
    for (final (command, args) in [
      ('make:model', ['Post']),
      ('migrate', ['--force']),
      ('migrate', <String>[]),
      ('route:list', <String>[]),
      ('help', ['migrate:fresh']),
    ]) {
      expect(await refused(s, command, args), isFalse, reason: command);
    }
    expect(handed, [
      ['make:model', 'Post'],
      ['migrate', '--force'],
      ['migrate'],
      ['route:list'],
      ['help', 'migrate:fresh'],
    ]);
  });

  test('outside production: migrate:fresh, db:seed, cache:clear and '
      'migrate --seed are offered; db:transfer and project commands are '
      'not', () async {
    final s = await server(env: 'local');
    for (final command in ['migrate:fresh', 'db:seed', 'cache:clear', 'test']) {
      expect(await refused(s, command), isFalse, reason: command);
    }
    expect(await refused(s, 'migrate', ['--seed']), isFalse);
    expect(await refused(s, '--no-color', ['migrate:fresh']), isTrue);
    expect(await refused(s, 'db:transfer'), isTrue);
    expect(await refused(s, 'probe'), isTrue);
  });

  test(
    '--allow-command opens a project command, under its alias too, but '
    'not a long-running one or, in production, one that changes data',
    () async {
      final local = await server(
        env: 'local',
        allowed: {'probe', 'tinker', 'db:restore'},
      );
      expect(await refused(local, 'probe', ['--loud']), isFalse);
      expect(await refused(local, 'probe-alias'), isFalse);
      expect(await refused(local, 'db:restore'), isFalse);
      expect(await refused(local, 'tinker'), isTrue);

      final prod = await server(
        allowed: {'probe', 'db:restore', 'migrate:fresh'},
      );
      expect(await refused(prod, 'probe'), isFalse);
      expect(await refused(prod, 'db:restore', ['--force']), isTrue);
      expect(await refused(prod, 'migrate:fresh', ['--force']), isTrue);
    },
  );

  test('options that take an offered command outside the project are '
      'refused; paths inside it are handed on', () async {
    final s = await server(env: 'local');
    final outside = p.join(p.dirname(root.path), 'elsewhere.json');
    for (final (command, args) in [
      ('route:diff', ['--laravel=.']),
      ('route:diff', ['--laravel-json=../routes.json']),
      ('route:diff', ['--laravel-json=$outside']),
      ('openapi:generate', ['--output=../openapi.json']),
      ('openapi:generate', ['--output=$outside']),
      ('openapi:generate', ['--output=docs/../../openapi.json']),
      ('security:audit', ['--target=https://example.com']),
      ('security:audit', ['--output=../report.json']),
    ]) {
      expect(await refused(s, command, args), isTrue, reason: '$args');
    }
    for (final (command, args) in [
      ('route:diff', ['--laravel-json=routes.json']),
      ('openapi:generate', ['--output=docs/openapi.json']),
      ('openapi:generate', <String>[]),
      ('security:audit', ['--output=build/report.json']),
      ('security:audit', <String>[]),
    ]) {
      expect(await refused(s, command, args), isFalse, reason: '$args');
    }
  });

  test('without the runner, run_command refuses every command', () async {
    final s = await server(env: 'local', withRunner: false);
    expect(await refused(s, 'make:model', ['Post']), isTrue);
    expect(await refused(s, 'about'), isTrue);
  });

  test('the tool description lists what is offered here', () async {
    final s = await server(allowed: {'probe'});
    final response = (await s.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
    }))!;
    final tools = (response['result']! as Map)['tools'] as List<Object?>;
    final description =
        (tools.firstWhere((t) => (t! as Map)['name'] == 'run_command')!
                as Map)['description']!
            as String;
    expect(description, contains('make:*'));
    expect(description, contains('probe'));
    expect(description, contains('migrate'));
    expect(description, isNot(contains('migrate:fresh')));
  });

  group('end to end, with the command line dartisan really runs', () {
    Future<List<String>> tables() async {
      final app = project();
      await app.boot();
      try {
        return await app.run(
          () async => [
            for (final row in await DB.select(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name NOT LIKE 'sqlite_%' ORDER BY name",
            ))
              '${row['name']}',
          ],
        );
      } finally {
        await app.shutdown();
      }
    }

    Future<int> rows() async {
      final app = project();
      await app.boot();
      try {
        return await app.run(() => DB.table('notes').count());
      } finally {
        await app.shutdown();
      }
    }

    test('production: migrate runs; the forms above change nothing', () async {
      final s = await server(execute: true);
      expect(await refused(s, 'migrate', ['--force']), isFalse);
      expect(await tables(), containsAll(['migrations', 'notes']));
      for (final (command, args) in production) {
        expect(
          await refused(s, command, args),
          isTrue,
          reason: '$command $args',
        );
      }
      expect(await tables(), containsAll(['migrations', 'notes']));
      expect(await rows(), 0);
      expect(ProbeCommand.runs, isEmpty);
    });

    test('an opened project command runs as the parser read it, under its '
        'alias too', () async {
      final s = await server(env: 'local', allowed: {'probe'}, execute: true);
      expect(await refused(s, 'probe', ['--loud']), isFalse);
      expect(await refused(s, 'probe-alias'), isFalse);
      expect(ProbeCommand.runs, [
        ['probe', '--loud'],
        ['probe'],
      ]);
    });
  });

  group('mcp:serve --allow-command', () {
    Future<int> serve(List<String> args) => IOOverrides.runZoned(
      () => runnerFor('local').execute(['mcp:serve', ...args]),
      getCurrentDirectory: () => root,
      stderr: () => _Silent(),
    );

    for (final args in [
      ['--allow-command=probe'],
      ['--allow-write', '--allow-command=tinker'],
      ['--allow-write', '--allow-command=serve'],
      ['--allow-write', '--allow-command=probe-alias'],
      ['--allow-write', '--allow-command=no:such-command'],
    ]) {
      test('${args.join(' ')} is a usage error', () async {
        expect(await serve(args), 64);
      });
    }
  });
}

final class _Silent implements Stdout {
  @override
  void write(Object? object) {}

  @override
  void writeln([Object? object = '']) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
