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

  test('writes .mcp.json and AGENTS.md; a second run changes nothing', () {
    final changed = installMcp(root.path);
    expect(changed.map(p.basename), ['.mcp.json', 'AGENTS.md']);
    expect(jsonDecode(file('.mcp.json').readAsStringSync()), {
      'mcpServers': {'daravel': mcpServerEntry},
    });
    final guide = file('AGENTS.md').readAsStringSync();
    expect(guide, startsWith('# Agent guidelines'));
    expect(guide, contains('Daravel $daravelVersion'));
    expect(guide, contains('### Models'));
    expect(guide, isNot(contains('# Daravel conventions')));
    expect(installMcp(root.path), isEmpty);
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
