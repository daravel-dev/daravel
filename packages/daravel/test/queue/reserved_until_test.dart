import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

final class Ping extends Job {
  const Ping();

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext context) async {}
}

/// `QueuedJob.reservedUntil` is exact: the database queue never hands a
/// reserved job out before it, and does at that moment. It stores
/// `reserved_at` in whole seconds, so the reservation is 2 to 3 s long for
/// a `retry_after` of 3 s, depending on where in its second the pop fell.
void main() {
  forEachDatabase((open) {
    late DatabaseManager db;

    setUp(() async {
      db = open();
      final schema = await freshSchema(db, ['jobs', 'job_batches']);
      await const CreateJobsTable().up(schema);
    });
    tearDown(() => db.closeAll());

    // A second boundary, as epoch milliseconds.
    const second = 1800000000 * 1000;

    for (final (fraction, retryAfter, expected) in [
      (0, const Duration(seconds: 3), second + 3000),
      (500, const Duration(seconds: 3), second + 3000),
      (999, const Duration(seconds: 3), second + 3000),
      // retry_after counts in whole seconds: 2.5 s is 2.
      (999, const Duration(milliseconds: 2500), second + 2000),
    ]) {
      test('popped at .$fraction s with retry_after $retryAfter: reserved '
          'until exactly ${expected - second} ms past the second', () async {
        var now = DateTime.fromMillisecondsSinceEpoch(
          second + fraction,
          isUtc: true,
        );
        final queue = DatabaseQueue(
          db,
          retryAfter: retryAfter,
          clock: () => now,
        );
        await queue.push(JobPayload.forJob(const Ping()), queue: 'default');

        final first = (await queue.pop('default'))!;
        expect(first.reservedUntil!.millisecondsSinceEpoch, expected);

        now = DateTime.fromMillisecondsSinceEpoch(expected - 1, isUtc: true);
        expect(await queue.pop('default'), isNull, reason: '1 ms before');

        now = DateTime.fromMillisecondsSinceEpoch(expected, isUtc: true);
        final again = (await queue.pop('default'))!;
        expect(again.id, first.id);
        expect(again.attempts, 2);
      });
    }

    // extend: reserved_at becomes the extension's second, so the job is
    // kept until exactly that second + R, wherever in it the extension fell.
    for (final fraction in [0, 500, 999]) {
      test('extended at .$fraction s of the next second: kept until exactly '
          'that second + 3 s', () async {
        var now = DateTime.fromMillisecondsSinceEpoch(second, isUtc: true);
        final queue = DatabaseQueue(
          db,
          retryAfter: const Duration(seconds: 3),
          clock: () => now,
        );
        await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
        final job = (await queue.pop('default'))!;

        now = DateTime.fromMillisecondsSinceEpoch(
          second + 1000 + fraction,
          isUtc: true,
        );
        final until = await queue.extend(job);
        const expected = second + 1000 + 3000;
        expect(until!.millisecondsSinceEpoch, expected);

        now = DateTime.fromMillisecondsSinceEpoch(expected - 1, isUtc: true);
        expect(await queue.pop('default'), isNull, reason: '1 ms before');
        now = DateTime.fromMillisecondsSinceEpoch(expected, isUtc: true);
        expect((await queue.pop('default'))!.id, job.id);
      });
    }

    test('extend once another worker reserved the job: null, and its '
        'reservation is left alone', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(second, isUtc: true);
      final queue = DatabaseQueue(
        db,
        retryAfter: const Duration(seconds: 3),
        clock: () => now,
      );
      await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
      final mine = (await queue.pop('default'))!;
      now = DateTime.fromMillisecondsSinceEpoch(second + 3000, isUtc: true);
      final theirs = (await queue.pop('default'))!;
      expect(theirs.attempts, 2);

      now = DateTime.fromMillisecondsSinceEpoch(second + 4000, isUtc: true);
      expect(await queue.extend(mine), isNull);
      // Still theirs until second 3 + 3: not moved to second 4 + 3.
      now = DateTime.fromMillisecondsSinceEpoch(second + 6000, isUtc: true);
      expect((await queue.pop('default'))!.attempts, 3);
    });
  });
}
