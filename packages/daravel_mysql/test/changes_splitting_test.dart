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
      // An executable comment that is empty or closes before the
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
      // MariaDB runs compound statements outside a routine, and a
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

  test('a conditional comment before the first keyword or between '
      'the keywords read makes the text one that may change splitting', () {
    // The server may skip a conditional comment entirely (MySQL skips every
    // `/*M!…*/`; both skip `/*!N…*/` above their version), so what it holds
    // is not what runs: its content is not read.
    for (final sql in [
      "/*M!100000 SELECT 1 */ SET SESSION sql_mode='NO_BACKSLASH_ESCAPES'",
      '/*!999999 SAVEPOINT x */ SET NAMES latin1',
      '/*!999999 DO 1 */ EXECUTE stmt',
      '/*M!100000 SELECT 1 */ IF 1 THEN SET NAMES latin1; END IF',
      '/*!999999 SELECT 1 */ SET NAMES latin1',
      'BEGIN /*M!999999 WORK */ NOT ATOMIC SET NAMES latin1; END',
      'BEGIN /*!999999 WORK */ NOT ATOMIC SET NAMES latin1; END',
      'BEGIN NOT /*!999999 x */ ATOMIC SET NAMES latin1; END',
      'l /*!999999 x */ : LOOP SET NAMES latin1; END LOOP',
      '/* c */ /*!999999 SELECT 1 */ SET NAMES latin1',
      '/*!40101 SELECT 1 */',
      // A doubled backquote inside a backquoted label.
      '`a``b`: LOOP SET NAMES latin1; END LOOP',
      '`a``b` : BEGIN NOT ATOMIC SELECT 1; END',
    ]) {
      expect(MySqlDriver.changesSplitting(sql), isTrue, reason: sql);
    }
    // Without a conditional comment where it is read (`/*M` lacks its `!`,
    // a `!` that does not follow `/*`, one after the first word), these
    // stay as they were.
    for (final sql in [
      '/*M SELECT 1 */ SELECT 2',
      '/* ! */ SELECT 1',
      'SELECT 1 /*!999999 SET NAMES latin1 */',
      'BEGIN /* c */ WORK',
      '`a``b` = 1',
      '`a``b`',
      // A lowercase /*m! is a plain comment on both servers.
      '/*m!100000 SET NAMES latin1 */ SELECT 1',
    ]) {
      expect(MySqlDriver.changesSplitting(sql), isFalse, reason: sql);
    }
  });

  test('a hint after a word that cannot be a label keeps the texts '
      'checked; one after a possible label does not', () {
    for (final sql in [
      'SELECT /*!40001 SQL_NO_CACHE */ * FROM t',
      'select /*M!100000 STRAIGHT_JOIN */ 1',
      'INSERT /*!50000 IGNORE */ INTO t VALUES (1)',
      'UPDATE /*!50000 LOW_PRIORITY */ t SET a = 1',
      'DELETE /*!50000 QUICK */ FROM t',
      'WITH /*!80000 x */ c AS (SELECT 1) SELECT * FROM c',
    ]) {
      expect(MySqlDriver.changesSplitting(sql), isFalse, reason: sql);
    }
    for (final sql in [
      // An identifier that only starts with such a word, a quoted one,
      // or any other word: a label is possible.
      'select_x /*!999999 y */ : LOOP SET NAMES latin1; END LOOP',
      '`select` /*!999999 y */ : LOOP SET NAMES latin1; END LOOP',
      'binlog /*!999999 y */ : LOOP SET NAMES latin1; END LOOP',
      'lbl /*!999999 y */ : LOOP SET NAMES latin1; END LOOP',
    ]) {
      expect(MySqlDriver.changesSplitting(sql), isTrue, reason: sql);
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
