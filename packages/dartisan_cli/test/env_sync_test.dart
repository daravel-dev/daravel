import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:args/command_runner.dart';
import 'package:dartisan_cli/src/env_commands.dart';
import 'package:dartisan_cli/src/env_sync.dart';
import 'package:dartisan_cli/src/region_format.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dartisan env:sync` (W9.7): `EnvKeys` from `.env.example` only, with
/// example values copied only when they cannot be credentials.
void main() {
  const example = '''
APP_NAME=Daravel
APP_DEBUG=true
APP_PORT=8000
# @type String
APP_VERSION=2

# Laravel major (8 to 13) whose error and validation bodies to answer with
# COMPAT_LARAVEL_VERSION=12

DB_URL=postgres://admin:hunter2@db.internal:5432/app
REDIS_URL=redis://:s3cret@cache:6379
MAIL_FROM=ops@example.com
APP_KEY=base64:abcdef
SECRET_ROTATION_DAYS=30
QUOTED="hello world"
INLINE=value # a comment
EMPTY=
APP_NAME=duplicate
''';

  test('variables, types, comments and commented-out keys', () {
    final vars = {for (final v in parseEnvExample(example)) v.key: v};
    expect(vars.keys, isNot(contains('duplicate')));
    expect(vars['APP_NAME']!.value, 'Daravel');
    expect(vars['APP_DEBUG']!.type, 'bool');
    expect(vars['APP_PORT']!.type, 'int');
    expect(vars['APP_VERSION']!.type, 'String');
    final compat = vars['COMPAT_LARAVEL_VERSION']!;
    expect(compat.commentedOut, isTrue);
    expect(compat.type, 'int');
    expect(compat.doc, [
      'Laravel major (8 to 13) whose error and validation bodies to answer with',
    ]);
    expect(vars['QUOTED']!.value, 'hello world');
    expect(vars['INLINE']!.value, 'value');
    expect(vars['EMPTY']!.value, '');
  });

  test('a value is copied only when it cannot be a credential', () {
    final region = envRegion(parseEnvExample(example));
    for (final secret in ['hunter2', 's3cret', 'ops@example.com', 'abcdef']) {
      expect(region, isNot(contains(secret)), reason: secret);
    }
    expect(region, contains('Example in `.env.example`: `Daravel`'));
    // An int is copied even when the key names a secret word.
    expect(region, contains('Example in `.env.example`: `30`'));
    expect(region, contains("static const dbUrl = EnvKey<String>('DB_URL');"));
    expect(region, contains('Set in `.env.example` (value not copied)'));
    expect(
      region,
      contains(
        "static const compatLaravelVersion = EnvKey<int?>"
        "('COMPAT_LARAVEL_VERSION');",
      ),
    );
  });

  test('the synced file compiles and Env.of types the values', () async {
    final synced = syncEnvSource(
      null,
      example,
      formatter: RegionFormatter(),
    ).source;
    final dir = Directory(p.normalize(p.absolute('.dart_tool/env_sync')));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'env_keys.dart')).writeAsStringSync(synced);
    File(p.join(dir.path, 'use.dart')).writeAsStringSync('''
import 'package:daravel/daravel.dart';

import 'env_keys.dart';

void use(Env env) {
  final bool debug = env.of(EnvKeys.appDebug);
  final int port = env.of(EnvKeys.appPort);
  final String name = env.of(EnvKeys.appName);
  final int? compat = env.of(EnvKeys.compatLaravelVersion);
  final String key = EnvKeys.appKey;
  print([debug, port, name, compat, key]);
}
''');
    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    for (final name in ['env_keys.dart', 'use.dart']) {
      final path = p.join(dir.path, name);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      expect(
        result is ErrorsResult
            ? [
                for (final d in result.diagnostics)
                  d.diagnosticCode.lowerCaseName,
              ]
            : ['not analyzed'],
        isEmpty,
        reason: name,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('the command', () {
    late Directory project;
    final original = Directory.current;

    setUp(() {
      project = Directory.systemTemp.createTempSync('env_sync_');
      File(p.join(project.path, 'pubspec.yaml'))
          .writeAsStringSync('name: shop\nenvironment:\n  sdk: ^3.13.0\n');
      Directory(p.join(project.path, 'bootstrap')).createSync();
      File(p.join(project.path, '.env.example'))
          .writeAsStringSync('APP_NAME=Shop\nAPP_DEBUG=false\n');
      // A local .env with other keys and a secret: never read.
      File(p.join(project.path, '.env')).writeAsStringSync(
        'APP_NAME=Local\nLOCAL_ONLY=1\nDB_PASSWORD=do-not-copy\n',
      );
      Directory.current = project;
    });

    tearDown(() {
      Directory.current = original;
      project.deleteSync(recursive: true);
    });

    Future<int?> run([List<String> args = const []]) => (CommandRunner<int>(
      'dartisan',
      'test',
    )..addCommand(EnvSyncCommand())).run(['env:sync', ...args]);

    test('writes from .env.example only; --check after a change', () async {
      expect(await run(), 0);
      final file = File(p.join(project.path, 'lib', 'config', 'env_keys.dart'));
      final written = file.readAsStringSync();
      expect(written, contains("EnvKey<String>('APP_NAME')"));
      expect(written, isNot(contains('LOCAL_ONLY')));
      expect(written, isNot(contains('do-not-copy')));
      expect(written, isNot(contains('Local')));
      expect(await run(['--check']), 0);
      File(p.join(project.path, '.env.example'))
          .writeAsStringSync('APP_NAME=Shop\nAPP_DEBUG=false\nAPP_TZ=UTC\n');
      expect(await run(['--check']), 1);
      expect(file.readAsStringSync(), written);
      expect(await run(), 0);
      expect(file.readAsStringSync(), contains("'APP_TZ'"));
    });
  });
}
