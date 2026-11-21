import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mcp_install_'));
  tearDown(() => root.deleteSync(recursive: true));

  File file(String name) => File(p.join(root.path, name));

  test('writes .mcp.json, the launcher and AGENTS.md; a second run changes '
      'nothing', () {
    final changed = installMcp(root.path);
    expect(changed.map(p.basename), [
      '.mcp.json',
      'dartisan_mcp.dart',
      'AGENTS.md',
    ]);
    expect(jsonDecode(file('.mcp.json').readAsStringSync()), {
      'mcpServers': {
        'daravel': {
          'command': 'dart',
          'args': ['tool/dartisan_mcp.dart'],
        },
      },
    });
    expect(file(mcpLauncherPath).readAsStringSync(), dartisanMcpLauncher);
    final guide = file('AGENTS.md').readAsStringSync();
    expect(guide, startsWith('# Agent guidelines'));
    expect(guide, contains('Daravel $daravelVersion'));
    expect(guide, contains('(`dart tool/dartisan_mcp.dart`)'));
    expect(guide, contains('### Models'));
    expect(guide, isNot(contains('# Daravel conventions')));
    expect(installMcp(root.path), isEmpty);
  });

  test('the earlier `dart run` entry is replaced, a custom one kept', () {
    file('.mcp.json').writeAsStringSync(
      jsonEncode({
        'mcpServers': {'daravel': mcpDartRunServerEntry},
      }),
    );
    installMcp(root.path);
    Object? daravel() =>
        ((jsonDecode(file('.mcp.json').readAsStringSync()) as Map)['mcpServers']
            as Map)['daravel'];
    expect(daravel(), mcpServerEntry);

    file('.mcp.json').writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'daravel': {'command': 'custom'},
        },
      }),
    );
    installMcp(root.path);
    expect(daravel(), {'command': 'custom'});
  });

  test('an edited launcher is kept unless --force', () {
    final launcher = file(mcpLauncherPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('// mine\n');
    installMcp(root.path);
    expect(launcher.readAsStringSync(), '// mine\n');
    installMcp(root.path, force: true);
    expect(launcher.readAsStringSync(), dartisanMcpLauncher);
  });

  test(
    'the launcher imports dart:io only and passes format and strict analysis',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      expect(
        RegExp(
          r"^import '([^']+)';",
          multiLine: true,
        ).allMatches(dartisanMcpLauncher).map((m) => m.group(1)),
        ['dart:io'],
      );
      file('pubspec.yaml').writeAsStringSync(
        'name: launcher_check\nenvironment:\n  sdk: ^3.13.0\n',
      );
      file('analysis_options.yaml').writeAsStringSync(
        'analyzer:\n  language:\n    strict-casts: true\n'
        '    strict-inference: true\n    strict-raw-types: true\n',
      );
      installMcp(root.path);
      final format = await Process.run(Platform.resolvedExecutable, [
        'format',
        '--output=none',
        '--set-exit-if-changed',
        mcpLauncherPath,
      ], workingDirectory: root.path);
      expect(format.exitCode, 0, reason: '${format.stdout}');
      final analyze = await Process.run(Platform.resolvedExecutable, [
        'analyze',
        '--fatal-infos',
        mcpLauncherPath,
      ], workingDirectory: root.path);
      expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
    },
  );

  group('in a DDEV project', () {
    setUp(() {
      Directory(p.join(root.path, '.ddev')).createSync();
      file('.ddev/config.yaml').writeAsStringSync('name: shop\n');
    });

    Map<Object?, Object?> servers() =>
        (jsonDecode(file('.mcp.json').readAsStringSync()) as Map)['mcpServers']
            as Map;

    test('the server runs in the web container', () {
      final changed = installMcp(root.path);
      expect(changed.map(p.basename), ['.mcp.json', 'dartisan', 'AGENTS.md']);
      expect(servers()['daravel'], mcpDdevServerEntry);
      expect(servers()['daravel'], {
        'command': 'ddev',
        'args': ['dartisan', 'mcp:serve'],
      });
      final command = file('.ddev/commands/web/dartisan');
      expect(command.readAsStringSync(), ddevDartisanCommand);
      expect(
        command.readAsStringSync(),
        contains('dart run bin/dartisan.dart "\$@"'),
      );
      if (!Platform.isWindows) {
        expect(command.statSync().modeString(), startsWith('rwx'));
      }
      expect(
        file('AGENTS.md').readAsStringSync(),
        contains('(`ddev dartisan mcp:serve`)'),
      );
      expect(installMcp(root.path), isEmpty);
    });

    test('an entry left at the host default is fixed, a custom one kept', () {
      file('.mcp.json').writeAsStringSync(
        jsonEncode({
          'mcpServers': {'daravel': mcpServerEntry},
        }),
      );
      installMcp(root.path);
      expect(servers()['daravel'], mcpDdevServerEntry);

      file('.mcp.json').writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'daravel': {'command': 'custom'},
          },
        }),
      );
      installMcp(root.path);
      expect(servers()['daravel'], {'command': 'custom'});
    });

    test('an existing ddev command is not replaced', () {
      final command = file('.ddev/commands/web/dartisan')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# mine\n');
      installMcp(root.path);
      expect(command.readAsStringSync(), '# mine\n');
    });
  });

  test('keeps other servers and the rest of the guidelines file', () {
    file('.mcp.json').writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'other': {'command': 'x'},
          'daravel': {'command': 'custom'},
        },
      }),
    );
    file('CLAUDE.md').writeAsStringSync('# My project\n\nOwn notes.\n');
    installMcp(root.path, guidelines: 'CLAUDE.md');
    final servers =
        (jsonDecode(file('.mcp.json').readAsStringSync()) as Map)['mcpServers']
            as Map;
    expect(servers['other'], {'command': 'x'});
    expect(servers['daravel'], {'command': 'custom'}, reason: 'not forced');
    installMcp(root.path, guidelines: 'CLAUDE.md', force: true);
    expect(
      ((jsonDecode(file('.mcp.json').readAsStringSync()) as Map)['mcpServers']
          as Map)['daravel'],
      mcpServerEntry,
    );

    // An outdated section is replaced in place; text around it stays.
    final claude = file('CLAUDE.md');
    final outdated = claude.readAsStringSync().replaceFirst(
      'This project uses',
      'OUTDATED. This project uses',
    );
    claude.writeAsStringSync('$outdated\nAfter.\n');
    expect(installMcp(root.path, guidelines: 'CLAUDE.md'), [claude.path]);
    final text = claude.readAsStringSync();
    expect(text, startsWith('# My project\n\nOwn notes.\n'));
    expect(text, isNot(contains('OUTDATED')));
    expect(text, endsWith('\nAfter.\n'));
    expect('<!-- daravel:guidelines -->'.allMatches(text), hasLength(1));
  });
}
