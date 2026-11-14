import 'dart:async';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// SQL holding a NUL character made
/// `package:sqlite3` loop for ever (its statement loop stops advancing at
/// the NUL), and `sqlite3_exec` silently ran only what came before it.
/// Each call runs in an isolate of its own that is killed when it does not
/// answer: a synchronous loop cannot be interrupted from the test's own
/// isolate.
void main() {
  final nul = String.fromCharCode(0);

  /// Runs [call] on a fresh in-memory SQLite in another isolate: its error
  /// type, `ok`, or `hung` after [limit].
  Future<String> outcome(
    String call,
    String sql, {
    Duration limit = const Duration(seconds: 5),
  }) async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(_run, (port.sendPort, call, sql));
    try {
      return await port.first.timeout(limit) as String;
    } on TimeoutException {
      return 'hung';
    } finally {
      isolate.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  for (final call in ['select', 'statement', 'insertGetId', 'unprepared']) {
    for (final sql in [
      'SELECT 1$nul',
      nul,
      'SELECT 1$nul; DROP TABLE t',
      'INSERT INTO t VALUES (1);${nul}INSERT INTO t VALUES (2)',
    ]) {
      test('$call refuses SQL holding a NUL: '
          '${sql.replaceAll(nul, r'\0')}', () async {
        expect(await outcome(call, sql), 'QueryException(NulInSqlException)');
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }
}

Future<void> _run((SendPort, String, String) message) async {
  final (reply, call, sql) = message;
  final db = DatabaseManager(
    const DatabaseConfig(
      defaultConnection: 'sqlite',
      connections: {
        'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
      },
    ),
  );
  try {
    await db.statement('CREATE TABLE t (n int)');
    await switch (call) {
      'select' => db.select(sql),
      'statement' => db.statement(sql),
      'insertGetId' => db.insertGetId(sql),
      _ => db.unprepared(sql),
    };
    reply.send('ok');
  } on QueryException catch (error) {
    reply.send('QueryException(${error.previous.runtimeType})');
  } on Object catch (error) {
    reply.send('${error.runtimeType}');
  }
}
