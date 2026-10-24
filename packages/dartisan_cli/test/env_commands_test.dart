import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CommandRunner<int> runner;
  const key = 'base64:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_env');
    runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(EnvEncryptCommand(root: root.path))
      ..addCommand(EnvDecryptCommand(root: root.path))
      ..addCommand(EnvObfuscateCommand(root: root.path, random: Random(7)));
  });
  tearDown(() => root.deleteSync(recursive: true));

  File file(String name) => File(p.join(root.path, name));

  test('env:encrypt then env:decrypt restores the file', () async {
    file('.env').writeAsStringSync('APP_NAME=Demo\nDB_PASSWORD="p@ss"\n');
    expect(await runner.run(['env:encrypt', '--key=$key']), 0);
    final encrypted = file('.env.encrypted').readAsStringSync();
    expect(EnvironmentEncrypter.appearsEncrypted(encrypted), isTrue);
    expect(encrypted, isNot(contains('p@ss')));

    // Refuses to overwrite without --force.
    expect(await runner.run(['env:encrypt', '--key=$key']), 1);

    file('.env').deleteSync();
    expect(await runner.run(['env:decrypt', '--key=$key']), 0);
    expect(
      file('.env').readAsStringSync(),
      'APP_NAME=Demo\nDB_PASSWORD="p@ss"\n',
    );
    expect(await runner.run(['env:decrypt', '--key=$key']), 1);
  });

  test('--env, --readable, --prune and a wrong key', () async {
    file('.env.production').writeAsStringSync('A=1\nB=two\n');
    expect(
      await runner.run([
        'env:encrypt',
        '--key=$key',
        '--env=production',
        '--readable',
        '--prune',
        '--cipher=AES-256-GCM',
      ]),
      0,
    );
    expect(file('.env.production').existsSync(), isFalse);
    final readable = file('.env.production.encrypted').readAsStringSync();
    expect(readable, startsWith('A=ey'));
    expect(readable, contains('\nB=ey'));

    expect(
      await runner.run([
        'env:decrypt',
        '--key=${Encrypter.generateKey()}',
        '--env=production',
      ]),
      1,
    );
    expect(
      await runner.run([
        'env:decrypt',
        '--key=$key',
        '--env=production',
        '--filename=.env.restored',
      ]),
      0,
    );
    expect(file('.env.restored').readAsStringSync(), 'A=1\nB=two\n');
  });

  test('env:obfuscate hides values and the masks decode them', () async {
    file('.env').writeAsStringSync(
      'API_TOKEN=tok_live_secret\nAPP_NAME=Demo\nMAIL_2FA_ISSUER=Acme\n',
    );
    expect(
      await runner.run([
        'env:obfuscate',
        '--output=lib/env.dart',
        '--class=AppEnv',
        '--only=API_TOKEN,MAIL_2FA_ISSUER',
      ]),
      0,
    );
    final source = file('lib/env.dart').readAsStringSync();
    expect(source, contains('abstract final class AppEnv'));
    expect(source, isNot(contains('tok_live_secret')));
    expect(source, isNot(contains('APP_NAME')));
    expect(source, contains('static String get apiToken'));
    expect(source, contains('static String get mail2faIssuer'));
    expect(source, contains("'API_TOKEN': apiToken,"));

    List<int> bytes(String name) =>
        RegExp('static const List<int> $name = <int>\\[([^\\]]*)\\]')
            .firstMatch(source)!
            .group(1)!
            .split(', ')
            .map(int.parse)
            .toList();
    final mask = bytes('_kApiToken');
    final masked = bytes('_vApiToken');
    expect(
      utf8.decode([for (var i = 0; i < mask.length; i++) mask[i] ^ masked[i]]),
      'tok_live_secret',
    );
  });
}
