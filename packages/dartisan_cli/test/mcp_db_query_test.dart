import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// `mcp:serve` db_query on SQLite, and on PostgreSQL / MySQL when
/// `DARAVEL_TEST_PG` / `DARAVEL_TEST_MYSQL` are set; with
/// `DARAVEL_TEST_MARIADB=1` the MySQL server is MariaDB and is also used
/// through a `mariadb` connection.
void main() {
  DatabaseManager fromUrl(String driver, String url) {
    final uri = Uri.parse(url);
    final user = uri.userInfo.split(':');
    return DatabaseManager(
      DatabaseConfig(
        defaultConnection: driver,
        connections: {
          driver: ConnectionConfig(
            driver: driver,
            database: uri.path.replaceFirst('/', ''),
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            username: user.first,
            password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
          ),
        },
      ),
      drivers: const {
        'mysql': MySqlDriver.fromConfig,
        'mariadb': MySqlDriver.fromConfig,
      },
    );
  }

  final databases = <String, DatabaseManager Function()>{
    'sqlite': () => DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    ),
    if (Platform.environment['DARAVEL_TEST_PG'] case final String url
        when url.isNotEmpty)
      'pgsql': () => fromUrl('pgsql', url),
    if (Platform.environment['DARAVEL_TEST_MYSQL'] case final String url
        when url.isNotEmpty)
      'mysql': () => fromUrl('mysql', url),
    if ((
          Platform.environment['DARAVEL_TEST_MYSQL'],
          Platform.environment['DARAVEL_TEST_MARIADB'],
        )
        case (final String url, '1') when url.isNotEmpty)
      'mariadb': () => fromUrl('mariadb', url),
  };

  for (final MapEntry(key: name, value: open) in databases.entries) {
    group(name, () {
      late DatabaseManager db;

      setUp(() async {
        db = open();
        await db.statement('DROP TABLE IF EXISTS mcp_q');
        await db.statement('CREATE TABLE mcp_q (id INTEGER, name VARCHAR(50))');
        for (final (id, n) in [(1, 'a'), (2, 'b'), (3, 'c')]) {
          await db.table('mcp_q').insert({'id': id, 'name': n});
        }
      });
      tearDown(() async {
        await db.statement('DROP TABLE IF EXISTS mcp_q');
        await db.closeAll();
      });

      Future<int> count() async => (await db.table('mcp_q').count()).toInt();

      test('selects with bindings, CTEs and EXPLAIN; limits rows', () async {
        final all = await readOnlySelect(
          db,
          'SELECT id, name FROM mcp_q WHERE id > ? ORDER BY id;',
          bindings: [1],
        );
        expect([for (final r in all.rows) '${r['name']}'], ['b', 'c']);
        expect(all.truncated, isFalse);
        final limited = await readOnlySelect(
          db,
          'SELECT id FROM mcp_q ORDER BY id',
          limit: 2,
        );
        expect(limited.rows, hasLength(2));
        expect(limited.truncated, isTrue);
        final cte = await readOnlySelect(
          db,
          'WITH x AS (SELECT id FROM mcp_q) SELECT COUNT(*) AS n FROM x',
        );
        expect('${cte.rows.single['n']}', '3');
        expect(
          (await readOnlySelect(db, 'EXPLAIN SELECT * FROM mcp_q')).rows,
          isNotEmpty,
        );
      });

      test('refuses writes and several statements; writes work after', () async {
        for (final sql in [
          'DELETE FROM mcp_q',
          'UPDATE mcp_q SET name = 1',
          'SELECT 1; DELETE FROM mcp_q',
          'DROP TABLE mcp_q',
        ]) {
          await expectLater(
            readOnlySelect(db, sql),
            throwsArgumentError,
            reason: sql,
          );
        }
        // A data-modifying CTE is caught by the database or the wrapper.
        await expectLater(
          readOnlySelect(
            db,
            'WITH gone AS (DELETE FROM mcp_q RETURNING id) SELECT * FROM gone',
          ),
          throwsA(anything),
        );
        expect(await count(), 3);
        // The connection is writable again after a read-only query.
        await db.table('mcp_q').insert({'id': 4, 'name': 'd'});
        expect(await count(), 4);
      });

      if (name == 'mysql' || name == 'mariadb') {
        test('the transaction is read-only on the server', () async {
          await db.statement(
            'CREATE TABLE IF NOT EXISTS mcp_locked (id INT) ENGINE=InnoDB',
          );
          addTearDown(() => db.statement('DROP TABLE IF EXISTS mcp_locked'));
          // Refused by the server, not by the statement check. A shared
          // lock (LOCK IN SHARE MODE) is allowed, and released by the
          // rollback right after the read.
          await expectLater(
            readOnlySelect(db, 'SELECT id FROM mcp_q FOR UPDATE'),
            throwsA(
              predicate((Object e) => '$e'.contains('READ ONLY transaction')),
            ),
          );
          await expectLater(
            readOnlySelect(db, "SELECT GET_LOCK('mcp', 0) AS l"),
            throwsArgumentError,
          );
          // Writes work after, on every pooled connection.
          await db.table('mcp_q').insert({'id': 5, 'name': 'e'});
          expect(await count(), 4);
        });

        test(
          'a long statement is stopped at the timeout',
          () async {
            await expectLater(
              readOnlySelect(
                db,
                'SELECT SLEEP(5) AS s',
                timeout: const Duration(milliseconds: 200),
              ),
              throwsA(anything),
            );
          },
          skip:
              name == 'mysql' &&
                  Platform.environment['DARAVEL_TEST_MARIADB'] == '1'
              ? 'MariaDB ignores the MAX_EXECUTION_TIME hint of a mysql connection'
              : false,
        );
      }

      if (name == 'mariadb') {
        test('NEXTVAL fails in the read-only transaction', () async {
          await db.statement('CREATE SEQUENCE IF NOT EXISTS mcp_seq');
          addTearDown(() => db.statement('DROP SEQUENCE IF EXISTS mcp_seq'));
          await expectLater(
            readOnlySelect(db, 'SELECT NEXTVAL(mcp_seq) AS v'),
            throwsA(
              predicate((Object e) => '$e'.contains('READ ONLY transaction')),
            ),
          );
          final next = await db.select('SELECT NEXTVAL(mcp_seq) AS v');
          expect('${next.single['v']}', '1', reason: 'the sequence is unused');
        });
      }

      if (name == 'pgsql') {
        test(
          'functions that write fail in the read-only transaction',
          () async {
            await db.statement('DROP SEQUENCE IF EXISTS mcp_seq');
            await db.statement('CREATE SEQUENCE mcp_seq');
            addTearDown(() => db.statement('DROP SEQUENCE IF EXISTS mcp_seq'));
            await expectLater(
              readOnlySelect(db, "SELECT nextval('mcp_seq') AS v"),
              throwsA(
                predicate((Object e) => '$e'.contains('read-only transaction')),
              ),
            );
            final next = await db.select("SELECT nextval('mcp_seq') AS v");
            expect(
              '${next.single['v']}',
              '1',
              reason: 'the sequence is unused',
            );
          },
        );
      }
    });
  }
}
