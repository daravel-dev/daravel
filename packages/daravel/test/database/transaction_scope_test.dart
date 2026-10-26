import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Transactions belong to one connection of one manager: queries on
/// another connection, or through another manager, never join them.
void main() {
  late Directory dir;
  late DatabaseManager db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tx_scope_');
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'main',
        connections: {
          'main': ConnectionConfig(
            driver: 'sqlite',
            database: p.join(dir.path, 'main.sqlite'),
          ),
          'other': ConnectionConfig(
            driver: 'sqlite',
            database: p.join(dir.path, 'other.sqlite'),
          ),
        },
      ),
    );
    for (final name in ['main', 'other']) {
      final executor = await db.executor(name);
      await executor.execute('CREATE TABLE items (name TEXT)');
    }
  });

  tearDown(() async {
    await db.closeAll();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  test('another connection inside a transaction is not part of it', () async {
    await expectLater(
      db.transaction(() async {
        await db.table('items').insert({'name': 'main'});
        await db.table('items', connection: 'other').insert({'name': 'other'});
        expect(db.inTransaction, isTrue);
        throw StateError('roll back main');
      }),
      throwsStateError,
    );
    // The rollback of `main` does not undo the write on `other`, which went
    // to its own database instead of `main`'s transaction.
    expect(await db.table('items').count(), 0);
    expect(await db.table('items', connection: 'other').count(), 1);
  });

  test('a transaction on another connection is its own', () async {
    await db.transaction(() async {
      await db.table('items').insert({'name': 'outer'});
      await expectLater(
        db.transaction(() async {
          await db.table('items', connection: 'other').insert({'name': 'x'});
          throw StateError('roll back other');
        }, connection: 'other'),
        throwsStateError,
      );
    });
    expect(await db.table('items').count(), 1);
    expect(await db.table('items', connection: 'other').count(), 0);
  });

  test('a second manager inside a transaction uses its own database', () async {
    final copy = db.forConnection(
      'copy',
      ConnectionConfig(
        driver: 'sqlite',
        database: p.join(dir.path, 'other.sqlite'),
      ),
    );
    addTearDown(copy.closeAll);
    await db.transaction(() async {
      await db.table('items').insert({'name': 'main'});
      expect(copy.inTransaction, isFalse);
      expect(await copy.table('items').count(), 0);
      await copy.table('items').insert({'name': 'copy'});
    });
    expect(await db.table('items').count(), 1);
    expect(await copy.table('items').count(), 1);
  });

  test('nested calls on the same connection are still savepoints', () async {
    await db.transaction(() async {
      await db.table('items').insert({'name': 'kept'});
      await expectLater(
        db.transaction(() async {
          await db.table('items').insert({'name': 'undone'});
          expect(db.transactionDepth, 2);
          throw StateError('roll back the savepoint');
        }),
        throwsStateError,
      );
    });
    expect((await db.table('items').get()).map((r) => r['name']), ['kept']);
  });
}
