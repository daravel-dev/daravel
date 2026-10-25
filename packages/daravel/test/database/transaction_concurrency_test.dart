import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

void main() => forEachDatabase(transactionConcurrencyTests);

/// Concurrency inside `DB.transaction`: sibling savepoints started with
/// `Future.wait`, and queries that outlive their transaction (a missing
/// `await`). Also run on MySQL and MariaDB by
/// daravel_mysql/test/orm_matrix_test.dart.
void transactionConcurrencyTests(DatabaseOpener open) {
  late DatabaseManager db;

  setUp(() async {
    db = open();
    final schema = await freshSchema(db, ['tx_items']);
    await schema.create('tx_items', (t) {
      t.id();
      t.string('name');
    });
  });
  tearDown(() => db.closeAll());

  Future<List<Object?>> names() async =>
      await db.table('tx_items').orderBy('id').pluck('name') as List<Object?>;

  Future<void> insert(String name) async {
    // A yield between statements, as real I/O interleaves them.
    await Future<void>.delayed(Duration.zero);
    await db.table('tx_items').insert({'name': name});
    await Future<void>.delayed(Duration.zero);
  }

  test('sibling savepoints in Future.wait keep each other\'s work', () async {
    await db.transaction(() async {
      final results = await Future.wait([
        db.transaction(() async {
          await insert('a1');
          await insert('a2');
          return 'a';
        }),
        db
            .transaction<String>(() async {
              await insert('b1');
              throw StateError('b fails');
            })
            .catchError((Object _) => 'b rolled back'),
      ]);
      expect(results, ['a', 'b rolled back']);
    });
    expect(await names(), ['a1', 'a2']);
  });

  test('50 parallel queries on one transaction connection', () async {
    // One connection carries the transaction; drivers queue its queries
    // (no interleaving on the wire), and a failure still rolls back all.
    await db.transaction(() async {
      await Future.wait([for (var i = 0; i < 25; i++) insert('p$i')]);
      final counts = await Future.wait([
        for (var i = 0; i < 25; i++) db.table('tx_items').count(),
      ]);
      expect(counts.toSet(), {25});
    });
    expect(await names(), hasLength(25));
    await expectLater(
      db.transaction(() async {
        await Future.wait([
          for (var i = 0; i < 25; i++) insert('q$i'),
          Future<void>.error(StateError('boom')),
        ]);
      }),
      throwsStateError,
    );
    // Give the remaining queued inserts a turn, then check nothing stayed.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await names(), hasLength(25));
  });

  test('nested savepoints inside a sibling do not deadlock', () async {
    await db.transaction(() async {
      await Future.wait([
        db.transaction(() async {
          await insert('outer-a');
          await db.transaction(() => insert('inner-a'));
        }),
        db.transaction(() => insert('outer-b')),
      ]);
    });
    expect(await names(), unorderedEquals(['outer-a', 'inner-a', 'outer-b']));
  });

  test('a query that outlives its transaction fails loudly', () async {
    final late = Completer<Object?>();
    await db.transaction(() async {
      await insert('kept');
      // The missing `await`: runs after the transaction has finished.
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 20),
          () => db.table('tx_items').insert({'name': 'escaped'}),
        ).then((_) => late.complete(null), onError: late.complete),
      );
    });
    final error = await late.future;
    expect(
      error,
      isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('after its transaction finished'),
      ),
    );
    expect(await names(), ['kept']);
  });
}
