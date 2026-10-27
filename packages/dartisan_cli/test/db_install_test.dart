import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The `bootstrap/app.dart` of a new `api` project.
String newBootstrap() => newProjectFiles(
  package: 'shop',
  appName: 'Shop',
  source: const PubHostedSource(),
  appKey: 'base64:test',
)['bootstrap/app.dart']!;

void main() {
  group('registerDriver', () {
    test('adds the import and the call after Application.configure', () {
      final source = registerDriver(newBootstrap(), driverPackages['pgsql']!)!;
      expect(
        source,
        contains("import 'package:daravel_postgres/daravel_postgres.dart';"),
      );
      expect(
        source,
        contains(
          '    Application.configure(basePath: basePath ?? Directory.current.path)\n'
          '        // DB_CONNECTION=pgsql (package:daravel_postgres).\n'
          '        .withPostgres()\n'
          '        .withEnv(',
        ),
      );
      // Imports stay grouped: the new one follows the last package import.
      expect(
        source.indexOf('daravel_postgres.dart'),
        greaterThan(source.indexOf('package:shop/app/models/user.dart')),
      );
      expect(
        source.indexOf('daravel_postgres.dart'),
        lessThan(source.indexOf("import '../routes/api.dart';")),
      );
    });

    test('is idempotent and leaves registered drivers alone', () {
      final once = registerDriver(newBootstrap(), driverPackages['sqlite']!)!;
      expect(registerDriver(once, driverPackages['sqlite']!), once);
      // New projects already register MySQL and MariaDB.
      final mysql = registerDriver(newBootstrap(), driverPackages['mysql']!);
      expect(mysql, newBootstrap());
    });

    test('skips parentheses inside strings when finding configure(...)', () {
      const source = '''
import 'package:daravel/daravel.dart';

Application createApp() =>
    Application.configure(basePath: ')(weird')
        .create();
''';
      final result = registerDriver(source, driverPackages['sqlite']!)!;
      expect(
        result,
        contains(
          "Application.configure(basePath: ')(weird')\n"
          '        // DB_CONNECTION=sqlite (package:daravel_sqlite).\n'
          '        .withSqlite()\n'
          '        .create();',
        ),
      );
    });

    test('is null without Application.configure', () {
      expect(
        registerDriver('void main() {}', driverPackages['sqlite']!),
        isNull,
      );
    });
  });

  group('addDependency', () {
    test('appends to the dependencies section and keeps the rest', () {
      const pubspec = '''
name: shop
dependencies:
  daravel: ^1.7.0
  http: ^1.2.0

dev_dependencies:
  test: ^1.33.0
''';
      final result = addDependency(pubspec, 'daravel_postgres', '^1.7.0');
      expect(
        result,
        contains(
          'dependencies:\n'
          '  daravel: ^1.7.0\n'
          '  http: ^1.2.0\n'
          '  daravel_postgres: ^1.7.0\n'
          '\n'
          'dev_dependencies:',
        ),
      );
      expect(addDependency(result, 'daravel_postgres', '^9.0.0'), result);
    });
  });

  group('addEnvExample', () {
    test('adds a commented block once', () {
      final once = addEnvExample('APP_NAME=Shop\n', driverPackages['pgsql']!);
      expect(
        once,
        contains(
          '# PostgreSQL (dartisan db:install pgsql)\n'
          '# DB_CONNECTION=pgsql\n'
          '# DB_HOST=127.0.0.1\n',
        ),
      );
      expect(once, startsWith('APP_NAME=Shop\n\n#'));
      expect(addEnvExample(once, driverPackages['pgsql']!), once);
    });

    test('PostgreSQL comes with an in-flight limit sized to its pool', () {
      final block = addEnvExample('', driverPackages['pgsql']!);
      expect(
        block,
        contains(
          '# DB_POOL_SIZE=10\n'
          '# Load shedding: about 4 x DB_POOL_SIZE requests at once per worker\n'
          '# HTTP_MAX_IN_FLIGHT=40\n',
        ),
      );
      // The other drivers are unchanged until they are measured.
      expect(
        addEnvExample('', driverPackages['mysql']!),
        isNot(contains('HTTP_MAX_IN_FLIGHT')),
      );
    });
  });

  group('db:install', () {
    late Directory project;
    late String previous;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('db_install_');
      final files = newProjectFiles(
        package: 'shop',
        appName: 'Shop',
        source: const PubHostedSource(),
        appKey: 'base64:test',
      );
      for (final path in [
        'pubspec.yaml',
        'bootstrap/app.dart',
        '.env.example',
      ]) {
        File(p.join(project.path, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(files[path]!);
      }
      previous = Directory.current.path;
      Directory.current = project;
    });

    tearDown(() async {
      Directory.current = previous;
      await project.delete(recursive: true);
    });

    String read(String path) =>
        File(p.join(project.path, path)).readAsStringSync();

    test(
      'updates pubspec, bootstrap and .env.example; then is a no-op',
      () async {
        final runner = DartisanRunner(() => throw StateError('not booted'));
        expect(await runner.run(['db:install', 'postgres', '--no-get']), 0);
        expect(
          read('pubspec.yaml'),
          contains('  daravel_postgres: ^$daravelVersion'),
        );
        expect(read('bootstrap/app.dart'), contains('.withPostgres()'));
        expect(read('.env.example'), contains('# DB_CONNECTION=pgsql'));
        final snapshot = [
          read('pubspec.yaml'),
          read('bootstrap/app.dart'),
          read('.env.example'),
        ];
        expect(await runner.run(['db:install', 'pgsql', '--no-get']), 0);
        expect([
          read('pubspec.yaml'),
          read('bootstrap/app.dart'),
          read('.env.example'),
        ], snapshot);
      },
    );

    test('rejects an unknown driver', () async {
      final runner = DartisanRunner(() => throw StateError('not booted'));
      expect(
        () => runner.run(['db:install', 'oracle', '--no-get']),
        throwsA(isA<UsageException>()),
      );
    });
  });

  test(
    'a new project with the sqlite and postgres drivers installed analyzes '
    'and passes its tests (e2e)',
    () async {
      final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
      final root = await Directory.systemTemp.createTemp('db_install_e2e_');
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
      // As `db:install` does, with the unpublished shims from this checkout.
      final pubspec = File(p.join(target, 'pubspec.yaml'));
      var text = pubspec.readAsStringSync();
      final bootstrap = File(p.join(target, 'bootstrap', 'app.dart'));
      var source = bootstrap.readAsStringSync();
      for (final driver in ['sqlite', 'pgsql']) {
        final package = driverPackages[driver]!;
        final path = p
            .join(repo, 'packages', package.package)
            .replaceAll(r'\', '/');
        text = addDependency(text, package.package, '{path: $path}');
        source = registerDriver(source, package)!;
      }
      pubspec.writeAsStringSync(text);
      bootstrap.writeAsStringSync(source);
      Future<ProcessResult> dart(List<String> args) =>
          Process.run(dartExecutable(), args, workingDirectory: target);
      final get = await dart(['pub', 'get']);
      expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
      await dart(['format', 'bootstrap/app.dart']);
      final analyze = await dart(['analyze', '--fatal-infos']);
      expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
      final test = await dart(['test']);
      expect(test.exitCode, 0, reason: '${test.stdout}');
    },
    skip: Platform.environment['DARAVEL_E2E'] == '1'
        ? false
        : 'set DARAVEL_E2E=1 to run (new + pub get + analyze + test, ~1 min)',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
