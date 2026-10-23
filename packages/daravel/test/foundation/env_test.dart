import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('parses comments, export, quotes, escapes and expansion', () {
    final values = Env.parse(r'''
# comment line
export APP_NAME="My App"
APP_ENV=local # inline comment
EMPTY=
QUOTED='single $NOT_EXPANDED'
ESCAPED="line1\nline2 \"q\""
BASE=http://localhost
URL=${BASE}/api
URL2=$BASE/v2
MISSING_REF=${NOPE}x
''');
    expect(values['APP_NAME'], 'My App');
    expect(values['APP_ENV'], 'local');
    expect(values['EMPTY'], '');
    expect(values['QUOTED'], r'single $NOT_EXPANDED');
    expect(values['ESCAPED'], 'line1\nline2 "q"');
    expect(values['URL'], 'http://localhost/api');
    expect(values['URL2'], 'http://localhost/v2');
    expect(values['MISSING_REF'], 'x');
  });

  test('rejects malformed lines', () {
    expect(() => Env.parse('NOT A LINE'), throwsA(isA<EnvException>()));
    expect(() => Env.parse('1BAD=x'), throwsA(isA<EnvException>()));
    expect(() => Env.parse('A="unterminated'), throwsA(isA<EnvException>()));
  });

  test('typed accessors', () {
    final env = Env.fromMap(<String, String>{
      'PORT': '8080',
      'DEBUG': 'true',
      'OFF': 'off',
      'LIST': 'a, b ,c',
    });
    expect(env.integer('PORT'), 8080);
    expect(env.integer('MISSING', 1), 1);
    expect(env.boolean('DEBUG'), isTrue);
    expect(env.boolean('OFF'), isFalse);
    expect(env.boolean('MISSING', true), isTrue);
    expect(env.list('LIST'), <String>['a', 'b', 'c']);
    expect(env.string('MISSING', 'x'), 'x');
    expect(env.maybeString('MISSING'), isNull);
    expect(() => env.string('MISSING'), throwsA(isA<EnvException>()));
    expect(() => env.integer('DEBUG'), throwsA(isA<EnvException>()));
    expect(() => env.boolean('LIST'), throwsA(isA<EnvException>()));
  });

  test('load merges file < platform < overrides', () async {
    final dir = await Directory.systemTemp.createTemp('daravel_env_');
    addTearDown(() => dir.delete(recursive: true));
    await File(p.join(dir.path, '.env')).writeAsString('A=file\nB=file\n');

    final env = await Env.load(
      basePath: dir.path,
      overrides: <String, String>{'B': 'override'},
    );
    expect(env.string('A'), 'file');
    expect(env.string('B'), 'override');
    final platformKey = Platform.environment.keys.first;
    expect(env.has(platformKey), isTrue);

    final isolated = await Env.load(basePath: dir.path, includePlatform: false);
    expect(isolated.has(platformKey), isFalse);
    expect(isolated.string('A'), 'file');
  });

  test('load tolerates a missing .env file', () async {
    final dir = await Directory.systemTemp.createTemp('daravel_env_');
    addTearDown(() => dir.delete(recursive: true));
    final env = await Env.load(basePath: dir.path, includePlatform: false);
    expect(env.toMap(), isEmpty);
  });
}
