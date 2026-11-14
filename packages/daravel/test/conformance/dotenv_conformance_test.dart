@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `Env.parse` reads a `.env` as Laravel does (phpdotenv v5.8.0,
/// [LaravelContract.dotenvValues]), lenient only where phpdotenv refuses a
/// line ([LaravelContract.dotenvRefused]).
void main() {
  String? read(String line) => Env.parse('A=one\n$line\n')['V'];

  for (final (line, value) in LaravelContract.dotenvValues) {
    test('$line reads as phpdotenv reads it', () {
      expect(read(line), value);
    });
  }

  for (final (line, value) in LaravelContract.dotenvRefused) {
    test('$line, which phpdotenv refuses, is read leniently', () {
      expect(read(line), value);
    });
  }

  test('a double-quoted value over several lines', () {
    expect(read('V="a\nb\\nc"'), 'a\nb\nc');
  });

  group('the lines Daravel 1.27 read differently', () {
    test('are told with their key and line, never their value', () {
      final changes = <(String, int)>[];
      Env.parse(
        'A=one\nPASSWORD=abc#123\nB=x #comment\nC="q#q"\nD=\'s#s\'\n'
        'E=#only\n',
        onCommentChange: (key, line) => changes.add((key, line)),
      );
      expect(changes, [('PASSWORD', 2), ('E', 6)]);
    });

    test('become a boot warning naming the file, key and line', () async {
      final root = Directory.systemTemp.createTempSync('dotenv_hash');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, '.env'))
          .writeAsStringSync('APP_ENV=testing\nDB_PASSWORD=abc#123\n');
      final env = await Env.load(basePath: root.path, includePlatform: false);
      expect(env.string('DB_PASSWORD'), 'abc');
      final issues = ConfigValidator().validate(
        env,
        ConfigRepository()..register(AppConfig.fromEnv(env)),
      );
      final warning = issues.singleWhere((i) => i.message.contains('#'));
      expect(warning.isError, isFalse);
      expect(warning.message, contains('.env line 2'));
      expect(warning.message, contains('DB_PASSWORD'));
      expect(warning.message, isNot(contains('abc')));
      expect(warning.message, isNot(contains('123')));
    });
  });
}
