import 'dart:io';

import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('addRedisService', () {
    test('a new compose file with Valkey and its volume', () {
      final compose = addRedisService('');
      expect(
        compose,
        startsWith('services:\n  valkey:\n    image: valkey/valkey:8\n'),
      );
      expect(compose, contains('      - "127.0.0.1:6379:6379"'));
      expect(compose, endsWith('volumes:\n  valkey-data:\n'));
    });

    test('next to the services and volumes already there', () {
      const existing =
          'services:\n  app:\n    image: myapp\n\nvolumes:\n  db:\n';
      final compose = addRedisService(existing, server: 'redis');
      expect(compose, contains('services:\n  redis:\n    image: redis:7\n'));
      expect(compose, contains('  app:\n    image: myapp\n'));
      expect(compose, contains('volumes:\n  redis-data:\n  db:\n'));
    });

    test('nothing when Redis or Valkey runs already', () {
      for (final image in [
        'redis:7.4',
        'valkey/valkey:8.1',
        'bitnami/redis:latest',
        '"redis:7"',
      ]) {
        final compose = 'services:\n  cache:\n    image: $image\n';
        expect(addRedisService(compose), compose, reason: image);
      }
      const other = 'services:\n  db:\n    image: postgres:17\n';
      expect(addRedisService(other), isNot(other));
    });
  });

  group('redis:install', () {
    late Directory project;
    setUp(() {
      project = Directory.systemTemp.createTempSync('redis_install_');
      final files = newProjectFiles(
        package: 'shop',
        appName: 'Shop',
        source: const PubHostedSource(),
        appKey: 'base64:test',
      );
      for (final path in [
        'pubspec.yaml',
        'bootstrap/app.dart',
        'bootstrap/commands.dart',
        '.env.example',
      ]) {
        File(p.join(project.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(files[path]!);
      }
    });
    tearDown(() {
      project.deleteSync(recursive: true);
    });

    // The project is the cwd of the command's zone only: the process cwd
    // is shared with the other test files, which run at the same time.
    Future<int?> dartisan(List<String> args) => IOOverrides.runZoned(
      () => DartisanRunner(() => throw StateError('not booted')).run(args),
      getCurrentDirectory: () => project,
    );

    String read(String path) =>
        File(p.join(project.path, path)).readAsStringSync();

    test('pubspec, bootstrap, commands, .env.example, compose; once', () async {
      expect(await dartisan(['redis:install', '--docker', '--no-get']), 0);
      expect(
        read('pubspec.yaml'),
        contains('  daravel_redis: ^$daravelVersion'),
      );
      final bootstrap = read('bootstrap/app.dart');
      expect(bootstrap, contains('.withRedis()'));
      expect(
        bootstrap,
        contains("import 'package:daravel_redis/daravel_redis.dart';"),
      );
      expect(
        bootstrap,
        contains('// CACHE_STORE=redis, QUEUE_CONNECTION=redis'),
      );
      final commands = read('bootstrap/commands.dart');
      expect(
        commands,
        contains("import 'package:daravel_redis/commands.dart';"),
      );
      expect(commands, contains('  ...redisCommands,'));
      expect(
        read('.env.example'),
        contains('# Redis (dartisan redis:install)'),
      );
      expect(read('.env.example'), contains('# CACHE_STORE=redis'));
      expect(read('compose.yaml'), contains('image: valkey/valkey:8'));

      final snapshot = [
        for (final f in [
          'pubspec.yaml',
          'bootstrap/app.dart',
          'bootstrap/commands.dart',
          '.env.example',
          'compose.yaml',
        ])
          read(f),
      ];
      expect(await dartisan(['redis:install', '--docker', '--no-get']), 0);
      expect([
        for (final f in [
          'pubspec.yaml',
          'bootstrap/app.dart',
          'bootstrap/commands.dart',
          '.env.example',
          'compose.yaml',
        ])
          read(f),
      ], snapshot);
    });
  });
  test(
    'a new project with Redis installed analyzes and passes its tests (e2e)',
    () async {
      final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
      final root = await Directory.systemTemp.createTemp('redis_install_e2e_');
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold a file.
        }
      });
      final target = p.join(root.path, 'shop');
      expect(
        await GlobalDartisanRunner().execute(['new', target, '--path=$repo']),
        0,
      );
      expect(
        await IOOverrides.runZoned(
          () =>
              DartisanRunner(() => throw StateError('not booted'))
                  .run(['redis:install', '--docker', '--no-get']),
          getCurrentDirectory: () => Directory(target),
        ),
        0,
      );
      // The unpublished package from this checkout.
      final pubspec = File(p.join(target, 'pubspec.yaml'));
      final path = p
          .join(repo, 'packages', 'daravel_redis')
          .replaceAll(r'\', '/');
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceFirst(
          '  daravel_redis: ^$daravelVersion',
          '  daravel_redis: {path: $path}',
        ),
      );
      Future<ProcessResult> dart(List<String> args) =>
          Process.run(dartExecutable(), args, workingDirectory: target);
      final get = await dart(['pub', 'get']);
      expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
      await dart(['format', 'bootstrap']);
      final analyze = await dart(['analyze', '--fatal-infos']);
      expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
      final test = await dart(['test']);
      expect(test.exitCode, 0, reason: '${test.stdout}');
    },
    skip: Platform.environment['DARAVEL_E2E'] == '1'
        ? false
        : 'set DARAVEL_E2E=1 to run (new + redis:install + analyze + test)',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
