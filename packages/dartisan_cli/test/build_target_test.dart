import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartisan_cli/src/project_commands.dart';
import 'package:test/test.dart';

void main() {
  group('buildCliArguments', () {
    test('the host build passes no target', () {
      expect(
        buildCliArguments(target: 'bin/server.dart', output: 'build/server'),
        ['build', 'cli', '-t', 'bin/server.dart', '-o', 'build/server'],
      );
    });

    test('another OS on the same architecture: --target-os only', () {
      expect(
        buildCliArguments(
          target: 'bin/server.dart',
          output: 'build/server',
          targetOs: 'linux',
        ),
        [
          'build',
          'cli',
          '-t',
          'bin/server.dart',
          '-o',
          'build/server',
          '--target-os=linux',
        ],
      );
    });

    test('another architecture stays on dart build cli (hooks run for it; '
        'dart compile exe refuses packages with build hooks)', () {
      final args = buildCliArguments(
        target: 'bin/server.dart',
        output: 'build/server',
        targetOs: 'linux',
        targetArch: 'arm64',
      );
      expect(args.take(2), ['build', 'cli']);
      expect(
        args,
        containsAllInOrder(['--target-os=linux', '--target-arch=arm64']),
      );
      expect(args, isNot(contains('compile')));
    });

    test('--target-arch alone keeps the host OS', () {
      expect(
        buildCliArguments(
          target: 'bin/dartisan.dart',
          output: 'build/dartisan',
          targetArch: 'arm64',
        ),
        [
          'build',
          'cli',
          '-t',
          'bin/dartisan.dart',
          '-o',
          'build/dartisan',
          '--target-arch=arm64',
        ],
      );
    });
  });

  test('bundleExecutableName has .exe only for a Windows target', () {
    expect(bundleExecutableName('server', 'linux'), 'server');
    expect(bundleExecutableName('server', 'macos'), 'server');
    expect(bundleExecutableName('dartisan', 'windows'), 'dartisan.exe');
    expect(
      bundleExecutableName('server', null),
      Platform.isWindows ? 'server.exe' : 'server',
    );
  });

  group('sqliteDownloadHint', () {
    test('explains the hash mismatch and offers --no-sqlite', () {
      const output =
          'Running build hooks...Unhandled exception:\n'
          'Bad state: Hash of downloaded file libsqlite3.x64.linux.so is '
          'bef140a1a96994029153dca8c00b1750b9a5a764fb9db2dc68d7bb40e8a29e8a, '
          'expected d3d1eac2a4e0eb84f4e8d94d820e5963fddfd11aa95179ea215ddc3bc7bd1078.\n'
          '  Building assets for package:sqlite3 failed.';
      final hint = sqliteDownloadHint(output);
      expect(hint, isNotNull);
      expect(hint, contains('libsqlite3.x64.linux.so'));
      expect(hint, contains('package:sqlite3 3.8.0'));
      expect(hint, contains('run the build again'));
      expect(hint, contains('--no-sqlite --force'));
    });

    test('says nothing about other failures', () {
      expect(sqliteDownloadHint('Error: compilation failed.'), isNull);
      expect(sqliteDownloadHint(''), isNull);
    });
  });

  group('dartisan build options', () {
    ({String? os, String? arch}) parse(List<String> args) {
      final command = BuildCommand();
      final runner = CommandRunner<int>('dartisan', 'test')
        ..addCommand(command);
      final results = runner.parse(['build', ...args]).command!;
      return (
        os: results['target-os'] as String?,
        arch: results['target-arch'] as String?,
      );
    }

    test('accept the supported targets', () {
      final r = parse(['--target-os=linux', '--target-arch=arm64']);
      expect(r.os, 'linux');
      expect(r.arch, 'arm64');
      expect(parse([]).os, isNull);
      expect(buildTargetOses, ['linux', 'macos', 'windows']);
      expect(buildTargetArchitectures, ['x64', 'arm64']);
    });

    test('reject anything else', () {
      expect(
        () => parse(['--target-os=android']),
        throwsA(isA<UsageException>()),
      );
      expect(
        () => parse(['--target-arch=ia32']),
        throwsA(isA<UsageException>()),
      );
    });
  });
}
