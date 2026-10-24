import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CommandRunner<int> runner;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_down');
    runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(DownCommand(root: root.path))
      ..addCommand(UpCommand(root: root.path));
  });
  tearDown(() => root.deleteSync(recursive: true));

  File downFile() => File(p.join(root.path, 'storage', 'framework', 'down'));

  test('down writes the Laravel down file and up removes it', () async {
    expect(
      await runner.run([
        'down',
        '--retry=60',
        '--secret=preview',
        '--except=/api/status',
      ]),
      0,
    );
    final data = jsonDecode(downFile().readAsStringSync()) as Map;
    expect(data['retry'], 60);
    expect(data['secret'], 'preview');
    expect(data['status'], 503);
    expect(data['except'], ['/api/status']);

    expect(await runner.run(['up']), 0);
    expect(downFile().existsSync(), isFalse);
    expect(await runner.run(['up']), 0, reason: 'up twice is fine');
  });

  test('--with-secret generates a 32-character secret', () async {
    expect(await runner.run(['down', '--with-secret']), 0);
    final data = jsonDecode(downFile().readAsStringSync()) as Map;
    expect(data['secret'], matches(RegExp(r'^[A-Za-z0-9]{32}$')));
  });

  test('rejects a non-numeric --retry', () {
    expect(
      runner.run(['down', '--retry=soon']),
      throwsA(isA<UsageException>()),
    );
  });
}
