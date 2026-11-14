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
      '/*M!100616 SET NAMES utf8mb4 */',
      '/*M! SET sql_mode = "" */',
      'EXECUTE stmt',
      "execute immediate 'SET sql_mode = \"\"'",
      'BEGIN NOT ATOMIC SET sql_mode = ""; END',
      'begin\n  not   atomic select 1; end',
      'SET STATEMENT max_statement_time = 1 FOR SELECT 1',
      // RSEQ 52: an executable comment that is empty or closes before the
      // keyword.
      '/*!40101*/ SET NAMES latin1',
      '/*!*/ SET NAMES latin1',
      '/*!40101 */ SET sql_mode = ""',
      '/*!40101*/ CALL p()',
      '/*!40101*/ EXECUTE s',
      '/*M!100616*/ SET sql_mode = ""',
      '/*!40101 /* inner */ SET x = 1 */',
      'BEGIN /*c*/ NOT ATOMIC SELECT 1; END',
      'BEGIN -- c\n NOT ATOMIC SELECT 1; END',
      'BEGIN # c\n NOT /* c */ ATOMIC SELECT 1; END',
      // RSEQ 57: MariaDB runs compound statements outside a routine, and a
      // SET NAMES inside one stays (measured on 11.8).
      'IF 1 THEN SET NAMES latin1; END IF',
      '/* c */ if 1 then set names latin1; end if',
      'CASE WHEN 1 THEN SET NAMES latin1; END CASE',
      'WHILE @w IS NULL DO SET @w = 1; END WHILE',
      'LOOP SET NAMES latin1; END LOOP',
      'REPEAT SET NAMES latin1; UNTIL 1 END REPEAT',
      'FOR i IN 1..1 DO SET NAMES latin1; END FOR',
      'l: BEGIN NOT ATOMIC SET NAMES latin1; END l',
      'l1 : LOOP SET NAMES latin1; LEAVE l1; END LOOP l1',
      '`my label`: BEGIN NOT ATOMIC SELECT 1; END',
      r'$x_9:REPEAT SELECT 1; UNTIL 1 END REPEAT',
      // A comment ends at \n, not at a lone \r (MySQL 8.4 and MariaDB 11.8).
      '-- x\r\nSET @c = 1',
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
      '/*M SET x = 1 */', // not executable without the !
      '-- only a comment',
      '',
      'SELECT IF(1, 2, 3)',
      'iffy',
      'formats',
      'x := 1', // an assignment, not a label
      // The whole text is a comment: MySQL 8.4 and MariaDB 11.8 run nothing
      // of it, since a comment ends at \n only.
      '--\rSET @c = 1',
      '-- \rSET @c = 1',
      '#\rSET @c = 1',
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
