@Tags(['integration'])
library;

import 'dart:io';

import 'package:mysql_dart/exception.dart';
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
