import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('the starter carries the suite e2e:install writes', () {
    // apps/daravel_starter/tests/e2e is generated with `dartisan
    // e2e:install`; regenerate it there (--force) after changing a template.
    final starter = p.join(
      Directory.current.path,
      '..',
      '..',
      'apps',
      'daravel_starter',
      e2eDirectory,
    );
    for (final MapEntry(key: path, value: content) in e2eTemplates().entries) {
      final file = File(p.join(starter, path));
      expect(file.existsSync(), isTrue, reason: '$path missing');
      expect(
        file.readAsStringSync().replaceAll('\r\n', '\n'),
        content,
        reason: '$path differs from its template',
      );
    }
  });

  test('specs, and the Playwright arguments', () {
    expect(
      e2eTemplates(auth: false).keys,
      isNot(contains(endsWith('auth.api.spec.ts'))),
    );
    expect(e2eSpec('AuthFlow', api: false).$1, 'specs/web/auth_flow.spec.ts');
    final (path, source) = e2eSpec('OrderTotals', api: true);
    expect(path, 'specs/api/order_totals.api.spec.ts');
    expect(source, contains("test.describe('order totals'"));
    expect(TestE2eCommand.playwrightArgs(), ['playwright', 'test']);
    expect(
      TestE2eCommand.playwrightArgs(api: true, ui: true, rest: ['-g', 'login']),
      ['playwright', 'test', '--project=api', '--ui', '-g', 'login'],
    );
  });

  group('commands', () {
    late Directory project;
    setUp(() {
      project = Directory.systemTemp.createTempSync('e2e_install_');
      File(p.join(project.path, 'pubspec.yaml'))
          .writeAsStringSync('name: shop\n');
      Directory(p.join(project.path, 'bootstrap')).createSync();
      File(p.join(project.path, 'routes', 'api.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "void apiRoutes(Router router) {\n"
          "  router.get('/ping', ping);\n"
          '}\n',
        );
    });
    tearDown(() => project.deleteSync(recursive: true));

    // The project is the cwd of the command's zone only: the process cwd
    // is shared with the other test files, which run at the same time.
    Future<int?> dartisan(List<String> args) => IOOverrides.runZoned(
      () => DartisanRunner(() => throw StateError('not booted')).run(args),
      getCurrentDirectory: () => project,
    );

    File file(String path) => File(p.join(project.path, e2eDirectory, path));

    test('e2e:install writes the suite once; make:e2e adds specs', () async {
      expect(await dartisan(['e2e:install']), 0);
      expect(file('playwright.config.ts').existsSync(), isTrue);
      expect(file('specs/api/health.api.spec.ts').existsSync(), isTrue);
      expect(
        file('specs/api/auth.api.spec.ts').existsSync(),
        isFalse,
        reason: 'no /api/auth routes in this project',
      );

      file('package.json').writeAsStringSync('{"edited": true}');
      expect(await dartisan(['e2e:install']), 0);
      expect(file('package.json').readAsStringSync(), '{"edited": true}');
      expect(await dartisan(['e2e:install', '--force']), 0);
      expect(
        file('package.json').readAsStringSync(),
        contains('@playwright/test'),
      );

      expect(await dartisan(['make:e2e', 'Checkout']), 0);
      expect(file('specs/web/checkout.spec.ts').existsSync(), isTrue);
      expect(await dartisan(['make:e2e', 'Orders', '--api']), 0);
      expect(file('specs/api/orders.api.spec.ts').existsSync(), isTrue);
      expect(await dartisan(['make:e2e', 'Orders', '--api']), 1);
    });

    test('--serve never reaches the database in the project\'s .env', () async {
      expect(await dartisan(['e2e:install']), 0);
      final config = file('playwright.config.ts').readAsStringSync();
      expect(config, contains('migrate:fresh --seed'));
      expect(config, contains("DB_CONNECTION: 'sqlite'"));
      expect(config, contains(r'DB_URL: `sqlite:${database}`'));

      // What the server boots with, on a project shared with Laravel.
      File(p.join(project.path, '.env')).writeAsStringSync(
        'DB_CONNECTION=pgsql\n'
        'DB_URL=pgsql://laravel:secret@db.example.com:5432/shared\n',
      );
      final env = await Env.load(
        basePath: project.path,
        includePlatform: false,
        overrides: const {
          'DB_CONNECTION': 'sqlite',
          'DB_URL': 'sqlite:database/e2e.sqlite',
        },
      );
      final connection = () {
        final config = DatabaseConfig.fromEnv(env, basePath: project.path);
        return config.connections[config.defaultConnection]!;
      }();
      expect(connection.driver, 'sqlite');
      expect(connection.database, p.join(project.path, 'database/e2e.sqlite'));
      expect(connection.host, isNull);
    });

    test('test:e2e explains what is missing', () async {
      expect(await dartisan(['test:e2e']), 1, reason: 'no suite');
      expect(await dartisan(['e2e:install']), 0);
      expect(await dartisan(['test:e2e']), 1, reason: 'no node_modules');
    });
  });
}
