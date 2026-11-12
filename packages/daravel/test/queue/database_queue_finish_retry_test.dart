import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// SQLite whose `DELETE FROM "jobs"` fails [failDeletes] times with an error
/// it calls retryable (as SQLite busy or a deadlock is), or with a plain one.
final class _FlakySqlite implements DatabaseDriver, RetryableErrors {
  _FlakySqlite(this._inner);

  final SqliteDriver _inner;
  static int failDeletes = 0;
  static bool retryable = true;
  static int deleteAttempts = 0;

  @override
  bool isRetryableError(Object error) =>
      error is StateError && error.message == 'database is locked';

  @override
  SqlDialect get dialect => _inner.dialect;
  @override
  String get name => _inner.name;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  Future<void> connect() => _inner.connect();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.select(sql, bindings);
  @override
  Future<int> execute(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) {
    if (sql.startsWith('DELETE FROM "jobs"')) {
      deleteAttempts++;
      if (failDeletes > 0) {
        failDeletes--;
        throw retryable
            ? StateError('database is locked')
            : StateError('disk I/O error');
      }
    }
    return _inner.execute(sql, bindings);
  }

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const <Object?>[],
  ]) => _inner.insertGetId(sql, bindings);
  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _inner.transaction(body);
}

/// Counts its runs.
final class Once extends Job {
  const Once();

  static int runs = 0;

  @override
  String get jobName => 'once';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async => runs++;
}

/// A transient error on the delete after a job ran no longer leaves its row
/// reserved (so the job ran again once `retry_after` passed): the delete is
/// retried while the reservation is still this worker's.
void main() {
  late Directory dir;
  late Application app;

  setUp(() async {
    Once.runs = 0;
    _FlakySqlite.failDeletes = 0;
    _FlakySqlite.retryable = true;
    _FlakySqlite.deleteAttempts = 0;
    dir = await Directory.systemTemp.createTemp('queue_finish_');
    app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': p.join(dir.path, 'db.sqlite'),
          'QUEUE_CONNECTION': 'database',
        })
        // The sqlite driver wrapped, under its own name (its dialect).
        .withDatabaseDriver(
          'sqlite',
          (name, connection) =>
              _FlakySqlite(SqliteDriver.fromConfig(name, connection)),
        )
        .withMigrations(const [CreateJobsTable()])
        .withJobs([JobDefinition('once', (_) => const Once())])
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });
  tearDown(() async {
    await app.shutdown();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file.
    }
  });

  Future<bool> runOne() => app.run(() async {
    final worker = QueueWorker(Queue.manager);
    return worker.runNextJob(Queue.connection(), const WorkerOptions());
  });

  test('a busy delete after the job ran is retried: the job ran once and '
      'its row is gone', () async {
    await app.run(() => Queue.push(const Once()));
    _FlakySqlite.failDeletes = 2;
    expect(await runOne(), isTrue);
    expect(Once.runs, 1);
    expect(_FlakySqlite.deleteAttempts, 3, reason: 'two failures, then done');
    expect(await app.run(() => Queue.connection().size('default')), 0);
    expect(await runOne(), isFalse, reason: 'nothing left to run again');
    expect(Once.runs, 1);
  });

  test('an error a retry cannot clear is not retried: the row stays, so the '
      'job runs again after retry_after (at-least-once)', () async {
    await app.run(() => Queue.push(const Once()));
    _FlakySqlite.failDeletes = 1;
    _FlakySqlite.retryable = false;
    await runOne().then<bool>((ran) => ran, onError: (Object _) => true);
    expect(Once.runs, 1);
    expect(_FlakySqlite.deleteAttempts, 1, reason: 'not retried');
    expect(await app.run(() => Queue.connection().size('default')), 1);
  });
}
