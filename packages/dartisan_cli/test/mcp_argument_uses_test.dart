import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every option and the positional arguments of every command
/// `run_command` offers is classified in [mcpArgumentUses], so a new one
/// cannot reach a path unchecked; and [mcpProjectPath], the check of the
/// paths.
void main() {
  group('mcpArgumentUses', () {
    final runner = DartisanRunner(
      () => Application.configure(basePath: '.').create(),
    );
    final offered = {
      ...mcpOfferedCommands,
      ...mcpOfferedOutsideProduction,
      for (final MapEntry(:key, :value) in runner.commands.entries)
        if (key.startsWith('make:') && value.name == key) key,
    };

    for (final name in offered.toList()..sort()) {
      test('$name: every option and the positional arguments classified', () {
        final command = runner.commands[name];
        expect(command, isNotNull, reason: '$name is not a command');
        final uses = mcpArgumentUsesOf(name);
        expect(uses, isNotNull, reason: '$name is not in mcpArgumentUses');
        final options = command!.argParser.options.keys
            .where((option) => option != 'help')
            .toSet();
        expect(
          options.difference(uses!.keys.toSet()),
          isEmpty,
          reason: 'options of $name without a classification',
        );
        expect(uses.keys, contains(mcpPositional));
        if (!name.startsWith('make:')) {
          expect(
            uses.keys.toSet()
              ..remove(mcpPositional)
              ..removeAll(options),
            isEmpty,
            reason: 'classified options $name does not have',
          );
        }
      });
    }

    test('every classified command is offered', () {
      expect(mcpArgumentUses.keys.where((name) => name != 'make:*').toSet(), {
        ...mcpOfferedCommands,
        ...mcpOfferedOutsideProduction,
      });
    });

    test('the paths: what is written and what is read', () {
      List<String> of(McpArgumentUse use) => [
        for (final MapEntry(key: command, value: options)
            in mcpArgumentUses.entries)
          for (final MapEntry(key: option, value: kind) in options.entries)
            if (kind == use) '$command $option',
      ]..sort();
      expect(of(McpArgumentUse.writesPath), [
        'openapi:generate output',
        'security:audit output',
      ]);
      expect(of(McpArgumentUse.readsPath), [
        'route:diff laravel-json',
        'test $mcpPositional',
      ]);
      expect(of(McpArgumentUse.refused), [
        'route:diff laravel',
        'security:audit target',
      ]);
    });
  });

  group('mcpProjectPath', () {
    late Directory parent;
    late String root;
    late String real;

    setUp(() {
      parent = Directory.systemTemp.createTempSync('mcp_project_path');
      root = p.join(parent.path, 'project');
      Directory(p.join(root, 'docs')).createSync(recursive: true);
      File(p.join(root, 'docs', 'existing.json')).writeAsStringSync('{}');
      real = Directory(root).resolveSymbolicLinksSync();
    });
    tearDown(() => parent.deleteSync(recursive: true));

    String check(String value, {bool write = false, String? writeDefault}) =>
        mcpProjectPath(root, value, write: write, writeDefault: writeDefault);

    test('a path inside the project is returned absolute and resolved', () {
      expect(check('docs/new.json'), p.join(real, 'docs', 'new.json'));
      expect(
        check('docs/../docs/x/y.json'),
        p.join(real, 'docs', 'x', 'y.json'),
      );
      expect(check(p.join(root, 'a.json')), p.join(real, 'a.json'));
    });

    for (final value in [
      '',
      'a${String.fromCharCode(0)}b',
      r'\\?\C:\x',
      r'\\.\pipe\x',
      r'\\host\share\x',
      '//host/share/x',
      'C:x',
      'C:',
      r'C:..\x',
      'docs/x.json:stream',
      'CON',
      'con.txt',
      'docs/NUL',
      'LPT1.json',
      'com9',
      'docs/a.',
      'docs/a ',
      '../outside.json',
      'docs/../../outside.json',
    ]) {
      test(
        '"${value.replaceAll(String.fromCharCode(0), r'\0')}" is refused',
        () {
          expect(() => check(value), throwsStateError);
        },
      );
    }

    test('an absolute path outside is refused, also by the root of the '
        'drive', () {
      expect(() => check(p.join(parent.path, 'x.json')), throwsStateError);
      expect(() => check('/x.json'), throwsStateError);
    });

    test('writing: a file that exists only when it is the default', () {
      expect(() => check('docs/existing.json', write: true), throwsStateError);
      expect(() => check('docs', write: true), throwsStateError);
      expect(
        check(
          'docs/existing.json',
          write: true,
          writeDefault: 'docs/existing.json',
        ),
        p.join(real, 'docs', 'existing.json'),
      );
      expect(
        check('docs/existing.json'),
        p.join(real, 'docs', 'existing.json'),
      );
    });

    test('a link is refused, and a link on the way is resolved', () {
      final outside = Directory(p.join(parent.path, 'outside'))..createSync();
      final link = p.join(root, 'docs', 'escape');
      final made = Platform.isWindows
          ? Process.runSync('cmd', [
                  '/c',
                  'mklink',
                  '/J',
                  link,
                  outside.path,
                ]).exitCode ==
                0
          : (Link(link)..createSync(outside.path)).existsSync();
      if (!made) {
        markTestSkipped('this system refused to create a junction');
        return;
      }
      addTearDown(() {
        if (Platform.isWindows) {
          Process.runSync('cmd', ['/c', 'rmdir', link]);
        } else {
          Link(link).deleteSync();
        }
      });
      expect(() => check('docs/escape'), throwsStateError);
      expect(() => check('docs/escape/x.json'), throwsStateError);
      expect(
        () => check('docs/escape', write: true, writeDefault: 'docs/escape'),
        throwsStateError,
      );
    });
  });
}
