import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory laravel;
  late Directory daravel;
  late CommandRunner<int> runner;
  final key = Encrypter.generateKey();

  void writeLaravel(String env, {String version = 'v12.70.1'}) {
    File(p.join(laravel.path, 'artisan')).writeAsStringSync('<?php');
    File(p.join(laravel.path, 'composer.lock')).writeAsStringSync(
      '{"packages": [{"name": "laravel/framework", "version": "$version"}]}',
    );
    File(p.join(laravel.path, '.env')).writeAsStringSync(env);
  }

  setUp(() {
    laravel = Directory.systemTemp.createTempSync('adopt_laravel');
    daravel = Directory.systemTemp.createTempSync('adopt_daravel');
    runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(AdoptCommand(root: daravel.path));
  });
  tearDown(() {
    laravel.deleteSync(recursive: true);
    daravel.deleteSync(recursive: true);
  });

  test('copies the shared settings and reports missing tables', () async {
    Directory(p.join(laravel.path, 'database')).createSync();
    final db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(
            driver: 'sqlite',
            database: p.join(laravel.path, 'database', 'database.sqlite'),
          ),
        },
      ),
    );
    await db.statement('CREATE TABLE users (id INTEGER PRIMARY KEY)');
    await db.closeAll();
    writeLaravel(
      'APP_NAME="My Shop"\nAPP_KEY=$key\nDB_CONNECTION=sqlite\n'
      'DB_PASSWORD="p\$ss word#1"\nBCRYPT_ROUNDS=12\nMAIL_HOST=smtp\n',
    );
    File(p.join(daravel.path, '.env')).writeAsStringSync('APP_NAME=Mine\n');

    expect(await runner.run(['adopt', laravel.path]), 0);

    final env = Env.parse(
      File(p.join(daravel.path, '.env')).readAsStringSync(),
    );
    expect(env['APP_NAME'], 'Mine', reason: 'unrelated keys are kept');
    expect(env['APP_KEY'], key);
    expect(env['DB_PASSWORD'], r'p$ss word#1');
    expect(env['BCRYPT_ROUNDS'], '12');
    expect(env['CACHE_PREFIX'], 'daravel_cache_');
    expect(
      env['DB_DATABASE'],
      p.join(laravel.path, 'database', 'database.sqlite'),
    );
    expect(env.containsKey('MAIL_HOST'), isFalse);
    expect(
      File(p.join(daravel.path, '.env.before-adopt')).readAsStringSync(),
      'APP_NAME=Mine\n',
    );
  });

  test(
    '--check changes nothing; MySQL is adopted, SQL Server is not',
    () async {
      writeLaravel('APP_KEY=$key\nDB_CONNECTION=mysql\nDB_DATABASE=shop\n');
      final check = ['adopt', laravel.path, '--check', '--skip-database'];
      expect(await runner.run(check), 0);
      expect(File(p.join(daravel.path, '.env')).existsSync(), isFalse);
      expect(await runner.run(['adopt', laravel.path, '--skip-database']), 0);
      final env = File(p.join(daravel.path, '.env'));
      expect(Env.parse(env.readAsStringSync())['DB_CONNECTION'], 'mysql');

      env.deleteSync();
      writeLaravel('APP_KEY=$key\nDB_CONNECTION=sqlsrv\n');
      expect(await runner.run(['adopt', laravel.path, '--skip-database']), 1);
      expect(env.existsSync(), isFalse);
    },
  );

  test('rejects a folder that is not a Laravel project', () async {
    expect(await runner.run(['adopt', laravel.path]), 1);
  });

  group('session format', () {
    void writeSessionConfig(String line) {
      Directory(p.join(laravel.path, 'config')).createSync();
      File(p.join(laravel.path, 'config', 'session.php')).writeAsStringSync(
        '<?php\n\nreturn [\n    // Supported: "json", "php"\n$line\n];\n',
      );
    }

    test('without the key Laravel uses php', () {
      expect(laravelSessionSerialization(laravel.path, const {}), 'php');
      writeSessionConfig("    'lifetime' => 120,");
      expect(laravelSessionSerialization(laravel.path, const {}), 'php');
      writeSessionConfig("    // 'serialization' => 'json',");
      expect(laravelSessionSerialization(laravel.path, const {}), 'php');
    });

    test('the laravel/laravel 13 skeleton uses json', () {
      writeSessionConfig("    'serialization' => 'json',");
      expect(laravelSessionSerialization(laravel.path, const {}), 'json');
    });

    test('env() is resolved from the .env', () {
      writeSessionConfig(
        "    'serialization' => env('SESSION_FORMAT', 'json'),",
      );
      expect(laravelSessionSerialization(laravel.path, const {}), 'json');
      expect(
        laravelSessionSerialization(laravel.path, const {
          'SESSION_FORMAT': 'php',
        }),
        'php',
      );
    });

    test('adopt writes it to the .env', () async {
      writeLaravel(
        'APP_KEY=$key\nDB_CONNECTION=mysql\nDB_DATABASE=shop\n',
        version: 'v13.38.0',
      );
      writeSessionConfig("    'serialization' => 'json',");
      expect(await runner.run(['adopt', laravel.path, '--skip-database']), 0);
      final env = Env.parse(
        File(p.join(daravel.path, '.env')).readAsStringSync(),
      );
      expect(env['SESSION_SERIALIZATION'], 'json');
    });
  });

  test('Laravel 8 to 13 are supported; others are told what to check', () {
    for (final (version, major) in [
      ('8.83.27', 8),
      ('9.52.20', 9),
      ('10.48.29', 10),
      ('11.55.0', 11),
      ('12.70.1', 12),
      ('13.38.0', 13),
    ]) {
      expect(laravelCompatFor(version), major);
      expect(laravelVersionAdvice(version), isNull, reason: version);
    }
    for (final version in ['7.30.6', '14.0.0', 'dev-main']) {
      expect(laravelCompatFor(version), isNull);
      expect(laravelVersionAdvice(version), contains('Laravel 8 to 13'));
    }
  });

  test('adopt keeps the Laravel version for the wire formats', () async {
    writeLaravel(
      'APP_KEY=$key\nDB_CONNECTION=mysql\nDB_DATABASE=shop\n',
      version: 'v8.83.27',
    );
    expect(await runner.run(['adopt', laravel.path, '--skip-database']), 0);
    final env = Env.parse(
      File(p.join(daravel.path, '.env')).readAsStringSync(),
    );
    expect(env['COMPAT_LARAVEL_VERSION'], '8');
    expect(env['SESSION_SERIALIZATION'], 'php');
  });

  test('laravelVersion reads composer.lock', () {
    writeLaravel('', version: 'v11.55.0');
    expect(laravelVersion(laravel.path), '11.55.0');
  });
}
