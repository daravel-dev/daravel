@Tags(['integration', 'single-statement'])
library;

import 'dart:io';

import 'package:mysql_dart/exception.dart';
import 'package:daravel/daravel.dart' show NulInSqlException;
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// DB-1 (Reviewer RSEQ 49 #3): a statement without bindings went to MySQL
/// as text on a connection that announces multi-statement support, so
/// `SELECT 1; DROP TABLE t` ran both. Each new text is now checked with a
/// prepare (closed at once) and remembered per connection. Runs only with
/// `DARAVEL_TEST_MYSQL`; the trigger test needs a user that may create
/// triggers (`DARAVEL_TEST_MYSQL_ROOT`, or skipped).
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (url == null || url.isEmpty) {
    test(
      'single statements (skipped: DARAVEL_TEST_MYSQL not set)',
      () {},
      skip: true,
    );
    return;
  }

  MySqlDriver driver([String? from]) {
    final uri = Uri.parse(from ?? url);
    final user = uri.userInfo.split(':');
    return MySqlDriver(
      host: uri.host,
      port: uri.hasPort ? uri.port : 3306,
      database: uri.path.replaceFirst('/', ''),
      username: user.first,
      password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
      // One connection: the per-connection cache and the session counters
      // below are this one's.
      maxConnections: 1,
    );
  }

  late MySqlDriver db;
  setUp(() async {
    db = driver();
    await db.connect();
    await db.execute('DROP TABLE IF EXISTS db1_single');
    await db.execute('CREATE TABLE db1_single (n INT)');
  });
  tearDown(() async {
    await db.unprepared("SET SESSION sql_mode = DEFAULT");
    await db.execute('DROP TABLE IF EXISTS db1_single');
    await db.close();
  });

  Future<int> status(String name) async {
    final rows = await db.select("SHOW SESSION STATUS LIKE '$name'");
    return int.parse('${rows.single['Value']}');
  }

  Future<int> prepares() => status('Com_stmt_prepare');

  test('statements the prepared protocol does not take run alone, and a '
      'stack they start is still refused', () async {
    await db.execute('LOCK TABLES db1_single WRITE');
    await db.execute('UNLOCK TABLES');
    expect(await db.select('SHOW TABLES'), isNotEmpty);
    await db.execute('DROP PROCEDURE IF EXISTS db1_proc');
    await db.execute(
      'CREATE PROCEDURE db1_proc() BEGIN SELECT 1; SELECT 2; END',
    );
    await db.execute('DROP PROCEDURE db1_proc');
    await expectLater(
      db.execute(
        'LOCK TABLES db1_single WRITE; INSERT INTO db1_single VALUES (1)',
      ),
      throwsA(isA<MySQLServerException>()),
    );
    await db.unprepared('UNLOCK TABLES');
    expect(await db.select('SELECT n FROM db1_single'), isEmpty);
  });

  test('CREATE TRIGGER runs alone, and a stack it starts is refused', () async {
    final root = Platform.environment['DARAVEL_TEST_MYSQL_ROOT'];
    if (root == null || root.isEmpty) {
      markTestSkipped(
        'DARAVEL_TEST_MYSQL_ROOT not set (triggers need it '
        'with binary logging on)',
      );
      return;
    }
    final admin = driver(root);
    await admin.connect();
    addTearDown(admin.close);
    await admin.execute('DROP TRIGGER IF EXISTS db1_trigger');
    await admin.execute(
      'CREATE TRIGGER db1_trigger BEFORE INSERT ON db1_single '
      'FOR EACH ROW SET NEW.n = NEW.n + 1',
    );
    await admin.execute('DROP TRIGGER db1_trigger');
    await expectLater(
      admin.execute(
        'CREATE TRIGGER db1_trigger BEFORE INSERT ON db1_single '
        'FOR EACH ROW SET NEW.n = NEW.n; INSERT INTO db1_single VALUES (1)',
      ),
      throwsA(isA<MySQLServerException>()),
    );
    expect(await admin.select('SELECT n FROM db1_single'), isEmpty);
  });

  test('a text checked under one sql_mode is checked again after SET: the '
      'stack it becomes is refused', () async {
    await db.execute('DROP TABLE IF EXISTS db1_victim');
    await db.execute('CREATE TABLE db1_victim (n INT)');
    addTearDown(() => db.unprepared('DROP TABLE IF EXISTS db1_victim'));
    // One string literal while a backslash escapes; three statements once
    // it does not.
    const text = r"SELECT 'a\'; DROP TABLE db1_victim; -- ' AS v";
    expect(
      (await db.select(text)).single['v'],
      "a'; DROP TABLE db1_victim; -- ",
    );
    await db.execute("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'");
    await expectLater(db.select(text), throwsA(isA<MySQLServerException>()));
    expect(await db.select('SELECT COUNT(*) AS c FROM db1_victim'), [
      {'c': 0},
    ], reason: 'the table is still there');
  });

  test(
    'MariaDB: a mode changed inside a /*M! executable comment is noticed',
    () async {
      if ((Platform.environment['DARAVEL_TEST_MARIADB'] ?? '').isEmpty) {
        markTestSkipped('MariaDB only (DARAVEL_TEST_MARIADB)');
        return;
      }
      await db.execute('DROP TABLE IF EXISTS db1_victim');
      await db.execute('CREATE TABLE db1_victim (n INT)');
      addTearDown(() => db.unprepared('DROP TABLE IF EXISTS db1_victim'));
      const text = r"SELECT 'a\'; DROP TABLE db1_victim; -- ' AS v";
      await db.select(text);
      await db.execute(
        "/*M!100100 SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES' */",
      );
      await expectLater(db.select(text), throwsA(isA<MySQLServerException>()));
      expect(await db.select('SELECT COUNT(*) AS c FROM db1_victim'), [
        {'c': 0},
      ]);
    },
  );

  test('SQL holding a NUL is refused before it is sent: the server read the '
      'NUL as the end and ran what came before (RSEQ 52 #1)', () async {
    final nul = String.fromCharCode(0);
    for (final run in <Future<Object?> Function()>[
      () => db.select('SELECT 1${nul}junk'),
      () => db.execute(
        'INSERT INTO db1_single VALUES (1);${nul}INSERT INTO db1_single '
        'VALUES (2)',
      ),
      () => db.unprepared(
        'INSERT INTO db1_single VALUES (3);${nul}INSERT INTO db1_single '
        'VALUES (4)',
      ),
    ]) {
      await expectLater(run(), throwsA(isA<NulInSqlException>()));
    }
    expect(await db.select('SELECT n FROM db1_single'), isEmpty);
  });

  test(
    'a SET after an empty executable comment is noticed (RSEQ 52 #3)',
    () async {
      await db.execute('DROP TABLE IF EXISTS db1_victim');
      await db.execute('CREATE TABLE db1_victim (n INT)');
      addTearDown(() => db.unprepared('DROP TABLE IF EXISTS db1_victim'));
      const text = r"SELECT 'a\'; DROP TABLE db1_victim; -- ' AS v";
      await db.select(text);
      await db.execute(
        "/*!40101*/ SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'",
      );
      await expectLater(db.select(text), throwsA(isA<MySQLServerException>()));
      expect(await db.select('SELECT COUNT(*) AS c FROM db1_victim'), [
        {'c': 0},
      ]);
    },
  );

  test('a mode changed through PREPARE ... FROM and EXECUTE is noticed too', () async {
    await db.execute('DROP TABLE IF EXISTS db1_victim');
    await db.execute('CREATE TABLE db1_victim (n INT)');
    addTearDown(() => db.unprepared('DROP TABLE IF EXISTS db1_victim'));
    const text = r"SELECT 'a\'; DROP TABLE db1_victim; -- ' AS v";
    await db.select(text);
    await db.execute(
      "PREPARE db1_mode FROM 'SET SESSION sql_mode = \"NO_BACKSLASH_ESCAPES\"'",
    );
    await db.execute('EXECUTE db1_mode');
    await db.execute('DEALLOCATE PREPARE db1_mode');
    await expectLater(db.select(text), throwsA(isA<MySQLServerException>()));
    expect(await db.select('SELECT COUNT(*) AS c FROM db1_victim'), [
      {'c': 0},
    ]);
  });

  test(
    'a repeated text is checked once; CALL and SET check it again',
    () async {
      await prepares(); // its own text, checked once
      const text = 'SELECT COUNT(*) AS c FROM db1_single';
      final before = await prepares();
      for (var i = 0; i < 5; i++) {
        await db.select(text);
      }
      expect(await prepares() - before, 1);
      await db.execute('DROP PROCEDURE IF EXISTS db1_noop');
      await db.execute('CREATE PROCEDURE db1_noop() BEGIN END');
      addTearDown(() => db.unprepared('DROP PROCEDURE IF EXISTS db1_noop'));
      await db.execute('CALL db1_noop()');
      final afterCall = await prepares();
      await db.select(text);
      // The CALL emptied the cache, so reading afterCall already checked
      // the counter's own text again; the query is checked again here.
      expect(await prepares() - afterCall, 1);
    },
  );

  test('a statement the prepared protocol does not take (1295) checks the '
      'texts again, unless it is a lock, a savepoint or the like', () async {
    addTearDown(() => db.unprepared('DEALLOCATE PREPARE db1_ps'));
    await prepares(); // its own text, checked once
    const text = 'SELECT COUNT(*) AS c FROM db1_single';
    await db.select(text);
    final cached = await prepares();
    await db.select(text);
    expect(await prepares() - cached, 0, reason: 'remembered');
    // 1295 on MySQL 8.4 (prepared on MariaDB 11.8): kept either way.
    await db.execute('LOCK TABLES db1_single READ');
    await db.execute('UNLOCK TABLES');
    final afterLock = await prepares();
    await db.select(text);
    expect(await prepares() - afterLock, 0, reason: 'a lock changes nothing');
    // 1295 on both, and not a kind known to leave splitting alone.
    await db.execute("PREPARE db1_ps FROM 'SELECT 1'");
    // Reading afterPrepare checks the counter's own text again.
    final afterPrepare = await prepares();
    await db.select(text);
    expect(await prepares() - afterPrepare, 1);
  });

  test(
    'a savepoint repeated on a connection is checked once per text, '
    'whether the server prepares it (MariaDB) or answers 1295 (MySQL)',
    () async {
      await prepares(); // its own text, checked once
      const text = 'SELECT COUNT(*) AS c FROM db1_single';
      Future<void> nested() => db.transaction((tx) async {
        await tx.execute('SAVEPOINT daravel_sp_2');
        await tx.select(text);
        await tx.execute('RELEASE SAVEPOINT daravel_sp_2');
      });
      final first = await prepares();
      await nested();
      // SAVEPOINT, the SELECT and RELEASE, each checked the first time.
      expect(await prepares() - first, 3);
      final later = await prepares();
      for (var i = 0; i < 20; i++) {
        await nested();
      }
      expect(await prepares() - later, 0, reason: 'all remembered');
    },
  );

  test('MariaDB: a compound statement outside a routine checks the texts '
      'again (a SET NAMES inside one stays)', () async {
    if ((Platform.environment['DARAVEL_TEST_MARIADB'] ?? '').isEmpty) {
      markTestSkipped('MariaDB only (DARAVEL_TEST_MARIADB)');
      return;
    }
    addTearDown(() => db.unprepared('SET NAMES utf8mb4'));
    await prepares();
    const text = 'SELECT COUNT(*) AS c FROM db1_single';
    await db.select(text);
    await db.execute('IF 1 THEN SET NAMES latin1; END IF');
    expect(
      (await db.select('SELECT @@session.character_set_client AS cs'))
          .single['cs'],
      'latin1',
      reason: 'the SET NAMES in the block stayed',
    );
    final afterIf = await prepares();
    await db.select(text);
    expect(await prepares() - afterIf, 1);
  });

  group('RSEQ 65: a conditional comment the server skips', () {
    final mariadb =
        (Platform.environment['DARAVEL_TEST_MARIADB'] ?? '').isNotEmpty;

    test('hides no SET from the check: the stack a text becomes is '
        'refused', () async {
      await db.execute('DROP TABLE IF EXISTS db1_victim');
      await db.execute('CREATE TABLE db1_victim (n INT)');
      addTearDown(() => db.unprepared('DROP TABLE IF EXISTS db1_victim'));
      const text = r"SELECT 'a\'; DROP TABLE db1_victim; -- ' AS v";
      await db.select(text);
      const set =
          "/*M!100000 SELECT 1 */ SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'";
      if (mariadb) {
        // MariaDB runs the comment: `SELECT 1 SET …` is not a statement.
        await expectLater(
          db.execute(set),
          throwsA(isA<MySQLServerException>()),
        );
        return;
      }
      // MySQL skips the whole comment and runs the SET.
      await db.execute(set);
      expect(
        (await db.select('SELECT @@session.sql_mode AS m')).single['m'],
        contains('NO_BACKSLASH_ESCAPES'),
      );
      await expectLater(db.select(text), throwsA(isA<MySQLServerException>()));
      expect(await db.select('SELECT COUNT(*) AS c FROM db1_victim'), [
        {'c': 0},
      ], reason: 'the table is still there');
    });

    test('in front of SET NAMES: the texts are checked again', () async {
      addTearDown(() => db.unprepared('SET NAMES utf8mb4'));
      await prepares();
      const text = 'SELECT COUNT(*) AS c FROM db1_single';
      await db.select(text);
      // Both servers skip a version above their own.
      await db.execute('/*!999999 SELECT 1 */ SET NAMES latin1');
      expect(
        (await db.select('SELECT @@session.character_set_client AS cs'))
            .single['cs'],
        'latin1',
      );
      final after = await prepares();
      await db.select(text);
      expect(await prepares() - after, 1);
    });

    test('in front of a 1295 statement: a keyword inside it does not keep '
        'the texts', () async {
      addTearDown(() => db.unprepared('DEALLOCATE PREPARE db1_ps'));
      await prepares();
      const text = 'SELECT COUNT(*) AS c FROM db1_single';
      await db.select(text);
      await db.execute(
        "/*!999999 SAVEPOINT x */ PREPARE db1_ps FROM 'SELECT 1'",
      );
      final after = await prepares();
      await db.select(text);
      expect(await prepares() - after, 1);
    });

    test('MariaDB: between BEGIN and NOT ATOMIC', () async {
      if (!mariadb) {
        markTestSkipped('MariaDB only (DARAVEL_TEST_MARIADB)');
        return;
      }
      addTearDown(() => db.unprepared('SET NAMES utf8mb4'));
      await prepares();
      const text = 'SELECT COUNT(*) AS c FROM db1_single';
      await db.select(text);
      await db.execute(
        'BEGIN /*M!999999 WORK */ NOT ATOMIC SET NAMES latin1; END',
      );
      expect(
        (await db.select('SELECT @@session.character_set_client AS cs'))
            .single['cs'],
        'latin1',
        reason: 'the block ran and its SET NAMES stayed',
      );
      final after = await prepares();
      await db.select(text);
      expect(await prepares() - after, 1);
    });
  });

  test('1 000 distinct texts leave no prepared statement on the server, '
      'and a text over 4 096 is checked every time', () async {
    await status('Com_stmt_close');
    final opened = await prepares();
    final closed = await status('Com_stmt_close');
    for (var i = 0; i < 1000; i++) {
      await db.select('SELECT $i AS n');
    }
    final prepared = await prepares() - opened;
    final closedNow = await status('Com_stmt_close') - closed;
    expect(prepared, greaterThanOrEqualTo(1000));
    expect(
      closedNow,
      greaterThanOrEqualTo(prepared),
      reason: 'every check closed its statement',
    );

    final long =
        'SELECT 1 AS n FROM db1_single WHERE n IN '
        '(${List.filled(1500, '1').join(', ')})';
    expect(long.length, greaterThan(MySqlDriver.singleStatementMaxLength));
    final start = await prepares();
    for (var i = 0; i < 3; i++) {
      await db.select(long);
    }
    expect(await prepares() - start, 3);
  });
}
