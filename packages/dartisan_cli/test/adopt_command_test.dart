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
    '--check changes nothing; MySQL fails until its driver exists',
    () async {
      writeLaravel('APP_KEY=$key\nDB_CONNECTION=mysql\nDB_DATABASE=shop\n');
      expect(await runner.run(['adopt', laravel.path, '--check']), 1);
      expect(File(p.join(daravel.path, '.env')).existsSync(), isFalse);
      expect(await runner.run(['adopt', laravel.path]), 1);
      expect(File(p.join(daravel.path, '.env')).existsSync(), isFalse);
    },
  );

  test('rejects a folder that is not a Laravel project', () async {
    expect(await runner.run(['adopt', laravel.path]), 1);
  });

  test('laravelVersion reads composer.lock', () {
    writeLaravel('', version: 'v11.55.0');
    expect(laravelVersion(laravel.path), '11.55.0');
  });
}
