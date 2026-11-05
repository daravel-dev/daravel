import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

/// `DB.transaction(timeout:)` (ACT-05): a body still running when the
/// timeout passes is given up. Its writes roll back, the connection goes
/// back to the pool, the call throws [TransactionTimeoutException], and the
/// body's later queries throw it too instead of running.
void main() {
  const timeout = Duration(milliseconds: 150);

  forEachDatabase((open) {
    late DatabaseManager db;

    setUp(() async {
      db = open();
      final schema = await freshSchema(db, const ['tt_items']);
      await schema.create('tt_items', (table) {
        table.id();
        table.string('name');
      });
    });
    tearDown(() async {
      await (await freshSchema(db, const [
        'tt_items',
      ])).dropIfExists('tt_items');
      await db.closeAll();
    });

    Future<List<String>> names() async => [
      for (final row in await db.table('tt_items').orderBy('id').get())
        row['name']! as String,
    ];

    test('a body past the timeout rolls back and throws', () async {
      final late = Completer<Object>();
      await expectLater(
        db.transaction(() async {
          await db.table('tt_items').insert({'name': 'lost'});
          // An external call that hangs, holding the transaction open.
          await Future<void>.delayed(timeout * 3);
          try {
            await db.table('tt_items').insert({'name': 'after'});
            late.complete('ran');
          } on Object catch (error) {
            late.complete(error);
          }
        }, timeout: timeout),
        throwsA(isA<TransactionTimeoutException>()),
      );
      // The connection is back and the writes are gone.
      expect(await names(), isEmpty);
      // The body's query after the timeout did not run.
      expect(await late.future, isA<TransactionTimeoutException>());
      expect(await names(), isEmpty);
    });

    test('the connection serves the next transaction at once', () async {
      await expectLater(
        db.transaction(
          () => Completer<void>().future, // never completes
          timeout: timeout,
        ),
        throwsA(isA<TransactionTimeoutException>()),
      );
      await db.transaction(() async {
        await db.table('tt_items').insert({'name': 'next'});
      });
      expect(await names(), ['next']);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a body within the timeout commits as usual', () async {
      var committed = false;
      final result = await db.transaction(() async {
        await db.table('tt_items').insert({'name': 'kept'});
        await db.afterCommit(() => committed = true);
        return 42;
      }, timeout: const Duration(seconds: 10));
      expect(result, 42);
      expect(committed, isTrue);
      expect(await names(), ['kept']);
    });

    test('after-commit callbacks of a timed-out body never run', () async {
      var ran = false;
      await expectLater(
        db.transaction(() async {
          await db.afterCommit(() => ran = true);
          await Future<void>.delayed(timeout * 3);
        }, timeout: timeout),
        throwsA(isA<TransactionTimeoutException>()),
      );
      await Future<void>.delayed(timeout);
      expect(ran, isFalse);
    });

    test('a timed-out savepoint rolls back alone', () async {
      await db.transaction(() async {
        await db.table('tt_items').insert({'name': 'outer'});
        await expectLater(
          db.transaction(() async {
            await db.table('tt_items').insert({'name': 'inner'});
            await Future<void>.delayed(timeout * 3);
          }, timeout: timeout),
          throwsA(isA<TransactionTimeoutException>()),
        );
        await db.table('tt_items').insert({'name': 'outer again'});
      });
      expect(await names(), ['outer', 'outer again']);
    });

    test('a timeout is not retried', () async {
      var runs = 0;
      await expectLater(
        db.transaction(
          () async {
            runs++;
            await Future<void>.delayed(timeout * 3);
          },
          attempts: 3,
          timeout: timeout,
        ),
        throwsA(isA<TransactionTimeoutException>()),
      );
      expect(runs, 1);
    });
  });

  test('a timeout must be positive', () {
    final db = sqliteInMemory();
    for (final bad in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => db.transaction(() async {}, timeout: bad),
        throwsArgumentError,
      );
    }
  });
}
