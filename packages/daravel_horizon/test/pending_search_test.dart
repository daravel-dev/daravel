import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/src/pending_search.dart';
import 'package:test/test.dart';

final class Noop extends Job {
  const Noop();
  @override
  String get jobName => 'noop';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A queue of [ids] whose workers pop [popsPerRead] jobs from the head
/// after every read.
final class _PoppingQueue implements BrowsableQueueDriver {
  _PoppingQueue(this.ids, {this.popsPerRead = 0});

  final List<int> ids;
  final int popsPerRead;
  int reads = 0;

  @override
  Future<List<QueuedJobView>> pending(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) async {
    reads++;
    final page = [
      for (final id in ids.skip(offset).take(limit))
        QueuedJobView.fromStored(
          id: id,
          queue: queue,
          payload: '{}',
          attempts: 0,
          availableAt: DateTime.utc(2026),
        ),
    ];
    ids.removeRange(0, popsPerRead.clamp(0, ids.length));
    return page;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test('a job behind the first 1 000 pending is found (1 051 jobs on the '
      'database queue)', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'database',
        })
        .withLogLevel(LogLevel.critical)
        .withMigrations(const [CreateJobsTable()])
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() => App.make<Migrator>().run());
    final driver = await app.run(() async {
      for (var i = 0; i < 1051; i++) {
        await Queue.push(const Noop(), queue: 'a');
      }
      return App.make<QueueManager>().connection('database')
          as BrowsableQueueDriver;
    });
    final last = (await app.run(
      () => driver.pending('a', limit: 1, offset: 1050),
    )).single;
    // The one page the quarantine used to read does not hold it.
    final firstPage = await app.run(() => driver.pending('a', limit: 1000));
    expect(firstPage.map((v) => v.id), isNot(contains(last.id)));
    final found = await app.run(() => findPending(driver, 'a', '${last.id}'));
    expect(found.job?.id, last.id);
    final missing = await app.run(() => findPending(driver, 'a', 'nope'));
    expect(missing.job, isNull);
    expect(missing.exhausted, isTrue, reason: 'read to the end: gone');
  });

  test('pops between two pages do not hide the job, up to the overlap', () {
    Future<PendingSearch> search(int pops) => findPending(
      _PoppingQueue([for (var i = 0; i < 3000; i++) i], popsPerRead: pops),
      'a',
      '2900',
    );
    expect(search(200).then((s) => s.job?.id), completion(2900));
    expect(search(250).then((s) => s.job?.id), completion(2900));
  });

  test('stops at its limit and says so', () async {
    final queue = _PoppingQueue([for (var i = 0; i < 5000; i++) i]);
    final search = await findPending(queue, 'a', '4999', limit: 2000);
    expect(search.job, isNull);
    expect(search.exhausted, isFalse, reason: 'not read to the end');
    expect(search.read, lessThanOrEqualTo(2000));
  });
}
