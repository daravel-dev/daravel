import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// DB-1: which statements make a connection check its SQL texts again
/// (`MySqlDriver.changesSplitting`), and that the scan stays linear: the
/// regular expression it replaced backtracked exponentially on repeated
/// comments.
void main() {
  test('SET, CALL, EXECUTE and MariaDB BEGIN NOT ATOMIC, after blanks and '
      'comments', () {
    for (final sql in [
      "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'",
      '  set names utf8mb4',
      '/* why */ SET character_set_client = gbk',
      '-- why\nSET @a = 1',
      '#why\ncall p()',
      '/*!40101 SET NAMES utf8mb4 */',
      '/*!SET sql_mode = "" */',
      'EXECUTE stmt',
      "execute immediate 'SET sql_mode = \"\"'",
      'BEGIN NOT ATOMIC SET sql_mode = ""; END',
      'begin\n  not   atomic select 1; end',
      'SET STATEMENT max_statement_time = 1 FOR SELECT 1',
    ]) {
      expect(MySqlDriver.changesSplitting(sql), isTrue, reason: sql);
    }
  });

  test('other statements, and keywords that are not the first word', () {
    for (final sql in [
      'SELECT 1',
      "UPDATE t SET a = 1",
      'BEGIN',
      'begin work',
      'SELECT /* SET */ 1',
      'settings',
      '--set x', // not a comment without a blank after the dashes
      '/* unterminated SET',
      '-- only a comment',
      '',
    ]) {
      expect(MySqlDriver.changesSplitting(sql), isFalse, reason: sql);
    }
  });

  test('10 000 comments are scanned in linear time', () {
    for (final unit in ['/**/', '/* a */ ', '-- x\n', '#\n']) {
      for (final tail in ['select 1', 'set x = 1']) {
        final sql = '${unit * 10000}$tail';
        final watch = Stopwatch()..start();
        final result = MySqlDriver.changesSplitting(sql);
        expect(
          watch.elapsed,
          lessThan(const Duration(milliseconds: 200)),
          reason: '"$unit" + $tail',
        );
        expect(result, tail.startsWith('set'), reason: '"$unit" + $tail');
      }
    }
  });
}
