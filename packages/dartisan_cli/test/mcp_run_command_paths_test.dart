import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `run_command` keeps the files an offered command reads and writes
/// inside the project, and hands on the paths it checked, not the client's
/// text: a path given in a form Windows reads elsewhere, through a link
/// out of the project, or onto a file that exists is refused.
void main() {
  late Directory parent;
  late Directory root;

  setUp(() {
    parent = Directory.systemTemp.createTempSync('mcp_paths');
    root = Directory(p.join(parent.path, 'project'))..createSync();
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
    Directory(p.join(root.path, 'docs')).createSync();
    Directory(p.join(parent.path, 'outside')).createSync();
    File(p.join(root.path, '.env'))
        .writeAsStringSync('APP_ENV=production\nMARKER_VALUE=zq9marker7\n');
  });
  tearDown(() {
    // Links first: a recursive delete must not follow them out.
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is Link) {
        entity.deleteSync();
      }
    }
    if (Platform.isWindows) {
      // Junctions are listed as directories on Windows; delete them alone.
      for (final name in ['docs/escape', 'openapi.json']) {
        final path = p.join(root.path, name);
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          Process.runSync('cmd', ['/c', 'rmdir', path]);
        }
      }
    }
    parent.deleteSync(recursive: true);
  });

  Application project() => Application.configure(basePath: root.path)
      .withEnv({
        'APP_ENV': 'production',
        'APP_KEY': 'base64:${'A' * 43}=',
        'DB_DATABASE': p.join(root.path, 'database.sqlite'),
      })
      .withLogLevel(LogLevel.critical)
      .create();

  final handed = <List<String>>[];
  final outputs = <String>[];
  setUp(() {
    handed.clear();
    outputs.clear();
  });

  /// [execute]: the handed command line runs, in process, as the dartisan
  /// process would run it (from the project directory).
  Future<McpServer> server({bool execute = false}) async {
    final app = project();
    await app.boot();
    addTearDown(app.shutdown);
    return McpServer(
      app,
      allowWrite: true,
      runner: DartisanRunner(project),
      runCommand: (command, arguments) async {
        handed.add([command, ...arguments]);
        if (!execute) {
          return (exitCode: 0, stdout: '', stderr: '');
        }
        // ignore: close_sinks (stdout of the zone, never opened)
        final out = _Capture();
        // ignore: close_sinks (stderr of the zone, never opened)
        final err = _Capture();
        final code = await IOOverrides.runZoned(
          () => DartisanRunner(project).execute([command, ...arguments]),
          getCurrentDirectory: () => root,
          stdout: () => out,
          stderr: () => err,
        );
        outputs.add('${out.buffer}${err.buffer}');
        return (
          exitCode: code,
          stdout: '${out.buffer}',
          stderr: '${err.buffer}',
        );
      },
    );
  }

  /// The tool's answer as text, and whether it was a refusal that handed
  /// nothing on.
  Future<(bool, String)> call(
    McpServer s,
    String command,
    List<String> args,
  ) async {
    final before = handed.length;
    final response = (await s.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'run_command',
        'arguments': {'command': command, 'arguments': args},
      },
    }))!;
    final result = response['result'] as Map<String, Object?>?;
    final refused =
        (response['error'] != null || result?['isError'] == true) &&
        handed.length == before;
    return (refused, jsonEncode(response));
  }

  /// Makes [link] (inside the project) lead to [target] (a directory).
  bool linkDirectory(String link, String target) {
    if (Platform.isWindows) {
      return Process.runSync('cmd', [
            '/c',
            'mklink',
            '/J',
            link,
            target,
          ]).exitCode ==
          0;
    }
    Link(link).createSync(target);
    return true;
  }

  group('a path Windows reads elsewhere is refused', () {
    for (final value in [
      r'C:..\drive_relative.json',
      'C:drive_relative.json',
      r'\\?\C:\x\escape.json',
      r'\\host\share\escape.json',
      '//host/share/escape.json',
      'docs/spec.json:stream',
      'CON',
      'NUL.json',
      'docs/con.txt',
      'docs/trailing.',
      'docs/trailing ',
      '',
    ]) {
      test('openapi:generate --output="$value"', () async {
        final s = await server();
        expect(
          (await call(s, 'openapi:generate', ['--output=$value'])).$1,
          isTrue,
        );
      });
    }

    test('route:diff --laravel-json and security:audit --output too', () async {
      final s = await server();
      expect(
        (await call(s, 'route:diff', [r'--laravel-json=C:..\routes.json'])).$1,
        isTrue,
      );
      expect(
        (await call(s, 'security:audit', [r'--output=C:..\audit.json'])).$1,
        isTrue,
      );
    });
  });

  test('a link out of the project is not followed', () async {
    final linked = linkDirectory(
      p.join(root.path, 'docs', 'escape'),
      p.join(parent.path, 'outside'),
    );
    if (!linked) {
      markTestSkipped('this system refused to create a junction');
      return;
    }
    final s = await server();
    for (final (command, args) in [
      ('openapi:generate', ['--output=docs/escape/spec.json']),
      ('security:audit', ['--output=docs/escape/audit.json']),
      ('route:diff', ['--laravel-json=docs/escape/routes.json']),
    ]) {
      expect((await call(s, command, args)).$1, isTrue, reason: '$args');
    }
    expect(Directory(p.join(parent.path, 'outside')).listSync(), isEmpty);
  });

  test('a file that exists is not written over: .env stays', () async {
    final s = await server(execute: true);
    final before = File(p.join(root.path, '.env')).readAsStringSync();
    expect((await call(s, 'openapi:generate', ['--output=.env'])).$1, isTrue);
    expect((await call(s, 'security:audit', ['--output=.env'])).$1, isTrue);
    expect((await call(s, 'security:audit', ['--output=docs'])).$1, isTrue);
    expect(File(p.join(root.path, '.env')).readAsStringSync(), before);
  });

  test("openapi:generate writes its own default again, and a new file; "
      'the command line handed on carries the checked path', () async {
    File(p.join(root.path, 'openapi.json')).writeAsStringSync('{}');
    final s = await server(execute: true);
    expect((await call(s, 'openapi:generate', const [])).$1, isFalse);
    expect(
      (await call(s, 'openapi:generate', ['--output', 'docs/new.json'])).$1,
      isFalse,
    );
    expect(File(p.join(root.path, 'docs', 'new.json')).existsSync(), isTrue);
    final real = Directory(root.path).resolveSymbolicLinksSync();
    expect(handed.last, [
      'openapi:generate',
      '--output=${p.join(real, 'docs', 'new.json')}',
    ]);
  });

  test('the default output is refused when it is a link', () async {
    final linked = linkDirectory(
      p.join(root.path, 'openapi.json'),
      p.join(parent.path, 'outside'),
    );
    if (!linked) {
      markTestSkipped('this system refused to create a junction');
      return;
    }
    final s = await server();
    expect((await call(s, 'openapi:generate', const [])).$1, isTrue);
    expect(
      (await call(s, 'openapi:generate', ['--output=openapi.json'])).$1,
      isTrue,
    );
  });

  test('the client\'s text never reaches the dartisan process', () async {
    final s = await server();
    final real = Directory(root.path).resolveSymbolicLinksSync();
    // Given twice: the parser keeps one, and that one is what is checked
    // and handed on.
    expect(
      (await call(s, 'openapi:generate', [
        '--output=docs/a.json',
        '--output=docs/b.json',
      ])).$1,
      isFalse,
    );
    final line = handed.last;
    expect(line, hasLength(2));
    expect(line.first, 'openapi:generate');
    expect(line.last, startsWith('--output='));
    final path = line.last.substring('--output='.length);
    expect(p.isAbsolute(path), isTrue);
    expect(p.isWithin(real, path), isTrue);
    expect([
      p.join(real, 'docs', 'a.json'),
      p.join(real, 'docs', 'b.json'),
    ], contains(path));
    // An empty value, then what looks like one: refused, not read as the
    // path.
    expect(
      (await call(s, 'openapi:generate', ['--output=', 'docs/c.json'])).$1,
      isTrue,
    );
  });

  test('route:diff on a file that is not route JSON tells nothing of what '
      'it holds', () async {
    final s = await server(execute: true);
    final (_, answer) = await call(s, 'route:diff', ['--laravel-json=.env']);
    expect(answer, isNot(contains('zq9marker7')));
    expect(outputs.join(), isNot(contains('zq9marker7')));
  });
}

final class _Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
