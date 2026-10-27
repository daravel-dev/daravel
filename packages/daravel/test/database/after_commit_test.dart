import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `afterCommit` callbacks run once the outermost transaction commits, in
/// order, and never when the level that registered them rolled back: a
/// savepoint rolled back inside an outer transaction that goes on to
/// commit drops only its own.
void main() {
  late Directory dir;
  late DatabaseManager db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('after_commit_');
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'main',
        connections: {
          'main': ConnectionConfig(
            driver: 'sqlite',
            database: p.join(dir.path, 'main.sqlite'),
          ),
        },
      ),
    );
    await (await db.executor()).execute('CREATE TABLE items (name TEXT)');
  });

  tearDown(() async {
    await db.closeAll();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file.
    }
  });

  Future<int> count() async =>
      (await db.select('SELECT COUNT(*) AS n FROM items')).first['n']! as int;

  test('run after the outer commit, in order, once', () async {
    final ran = <String>[];
    await db.transaction(() async {
      await db.afterCommit(() => ran.add('outer-1'));
      await db.statement("INSERT INTO items VALUES ('a')");
      await db.transaction(() async {
        await db.afterCommit(() => ran.add('inner'));
        await db.statement("INSERT INTO items VALUES ('b')");
      });
      expect(ran, isEmpty, reason: 'a released savepoint is not a commit');
      await db.afterCommit(() => ran.add('outer-2'));
    });
    expect(ran, ['outer-1', 'inner', 'outer-2']);
    expect(await count(), 2);
  });

  test(
    'a rolled-back savepoint drops its callbacks, the outer keeps its own',
    () async {
      final ran = <String>[];
      await db.transaction(() async {
        await db.afterCommit(() => ran.add('outer'));
        await db.statement("INSERT INTO items VALUES ('kept')");
        try {
          await db.transaction(() async {
            await db.statement("INSERT INTO items VALUES ('dropped')");
            await db.afterCommit(() => ran.add('inner'));
            throw StateError('roll the savepoint back');
          });
        } on StateError {
          // The outer transaction goes on.
        }
        await db.afterCommit(() => ran.add('after'));
      });
      expect(ran, ['outer', 'after']);
      expect(await count(), 1);
    },
  );

  test('a rolled-back transaction runs nothing', () async {
    final ran = <String>[];
    await expectLater(
      db.transaction(() async {
        await db.statement("INSERT INTO items VALUES ('x')");
        await db.afterCommit(() => ran.add('never'));
        await db.transaction(() async {
          await db.afterCommit(() => ran.add('never either'));
        });
        throw StateError('abort');
      }),
      throwsStateError,
    );
    expect(ran, isEmpty);
    expect(await count(), 0);
  });

  test('outside a transaction the callback runs at once', () async {
    final ran = <String>[];
    await db.afterCommit(() => ran.add('now'));
    expect(ran, ['now']);
  });

  test(
    'a failing callback does not undo the commit; the rest are skipped',
    () async {
      final ran = <String>[];
      await expectLater(
        db.transaction(() async {
          await db.statement("INSERT INTO items VALUES ('committed')");
          await db.afterCommit(() => throw StateError('listener bug'));
          await db.afterCommit(() => ran.add('after the failure'));
        }),
        throwsStateError,
      );
      expect(await count(), 1, reason: 'the row was committed before');
      // As in Laravel (executeCallbacks runs them in order without catching).
      expect(ran, isEmpty);
    },
  );

  test('concurrent transactions keep their callbacks apart', () async {
    final ran = <String>[];
    Future<void> tx(String name, {required bool commit}) =>
        db.transaction(() async {
          await db.statement("INSERT INTO items VALUES ('$name')");
          await db.afterCommit(() => ran.add(name));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (!commit) {
            throw StateError(name);
          }
        });
    await Future.wait([
      tx('one', commit: true),
      tx('two', commit: false).catchError((Object _) {}),
      tx('three', commit: true),
    ]);
    expect(ran, unorderedEquals(['one', 'three']));
    expect(await count(), 2);
  });
}
