import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Fails before `BEGIN`, as a pool that times out does.
final class _Refusing implements DatabaseDriver {
  @override
  SqlDialect get dialect => SqlDialect.sqlite;
  @override
  String get name => 'refusing';
  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      throw StateError('no connection');
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late DatabaseManager db;
  late List<TransactionEvent> events;

  setUp(() async {
    db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    events = [];
    db.listenTransactions(events.add);
    await db.statement('CREATE TABLE t (a INTEGER)');
  });

  tearDown(() => db.closeAll());

  test('a commit', () async {
    await db.transaction(() => db.table('t').insert({'a': 1}));
    expect(events, hasLength(2));
    expect(events.first, isA<DbTransactionBeginning>());
    expect(events.last, isA<DbTransactionCommitted>());
    expect(events.map((e) => e.depth), [1, 1]);
    expect(events.first.connectionName, 'sqlite');
  });

  test('a rollback carries the error', () async {
    await expectLater(
      db.transaction<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    final last = events.last as DbTransactionRolledBack;
    expect(last.error, isA<StateError>());
    expect(last.depth, 1);
  });

  test('savepoints count their depth', () async {
    await db.transaction(() async {
      await db.transaction(() => db.table('t').insert({'a': 1}));
    });
    expect(events.map((e) => (e.runtimeType, e.depth)), [
      (DbTransactionBeginning, 1),
      (DbTransactionBeginning, 2),
      (DbTransactionCommitted, 2),
      (DbTransactionCommitted, 1),
    ]);
  });

  test('a savepoint that fails leaves the outer one to commit', () async {
    await db.transaction(() async {
      await expectLater(
        db.transaction<void>(() async => throw StateError('inner')),
        throwsStateError,
      );
    });
    expect(events[2], isA<DbTransactionRolledBack>());
    expect(events[2].depth, 2);
    expect(events.last, isA<DbTransactionCommitted>());
  });

  test('the application forwards them to its events', () async {
    final base = Directory.systemTemp.createTempSync('daravel_tx_events');
    addTearDown(() => base.deleteSync(recursive: true));
    final seen = <Object>[];
    final app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withEvents((events) {
          events
            ..listen<TransactionBeginning>(seen.add)
            ..listen<TransactionCommitted>(seen.add)
            ..listen<TransactionRolledBack>(seen.add);
        })
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      await DB.transaction(() async => 1);
      await expectLater(
        DB.transaction<void>(() async => throw StateError('no')),
        throwsStateError,
      );
    });
    await pumpEventQueue();
    expect(seen.map((e) => e.runtimeType), [
      TransactionBeginning,
      TransactionCommitted,
      TransactionBeginning,
      TransactionRolledBack,
    ]);
    expect((seen.last as TransactionRolledBack).error, isA<StateError>());
  });

  test('no connection: no rollback without a beginning', () async {
    final broken = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'refusing',
        connections: {
          'refusing': ConnectionConfig(driver: 'refusing', database: 'x'),
        },
      ),
      drivers: {'refusing': (name, connection) => _Refusing()},
    );
    addTearDown(broken.closeAll);
    final seen = <TransactionEvent>[];
    broken.listenTransactions(seen.add);
    await expectLater(broken.transaction(() async => 1), throwsStateError);
    expect(seen, isEmpty);
  });

  test('no listener, no change', () async {
    final quiet = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    addTearDown(quiet.closeAll);
    expect(await quiet.transaction(() async => 7), 7);
  });
}
