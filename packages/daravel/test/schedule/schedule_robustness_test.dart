// Issue #160: stopping the scheduler, failing filters and listeners, and
// onOneServer keys.
import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final List<String> ran = <String>[];

final class Greet extends Job {
  const Greet(this.name);
  final String name;
  @override
  String get jobName => 'greet';
  @override
  Map<String, Object?> toJson() => {'name': name};
  @override
  Future<void> handle(JobContext ctx) async => ran.add('greet:$name');
}

void main() {
  late Application app;
  final at = DateTime.utc(2026, 10, 24, 3, 0);

  setUp(() async {
    ran.clear();
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_schedule_')
                  .path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': 'sync',
              'QUEUE_UNIQUE_LOCK_STORE': 'database',
            })
            .withMigrations(const [CreateCacheTable()])
            .withJobs([
              JobDefinition('greet', (j) => Greet(j['name']! as String)),
            ])
            .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() => app.shutdown());

  Lock overlapLock(String name) =>
      Cache.store('database').lock('schedule:$name:* * * * *');

  group('stopping', () {
    test('releases the overlap lock of a task still running after the '
        'drain', () async {
      await app.run(() async {
        final gate = Completer<void>();
        final started = Completer<void>();
        App.make<Schedule>()
            .call(() {
              started.complete();
              return gate.future;
            })
            .everyMinute()
            .withoutOverlapping()
            .named('long');
        final scheduler = Scheduler(
          App.make<Schedule>(),
          environment: 'testing',
          lockStore: Cache.store('database'),
          clock: () => at,
        );
        final working = scheduler.work(tick: const Duration(milliseconds: 5));
        await started.future;
        expect(await overlapLock('long').currentOwner(), isNotNull);

        scheduler.stop(drain: const Duration(milliseconds: 20));
        await working;
        expect(await overlapLock('long').currentOwner(), isNull);
        expect(scheduler.runningTasks, 0);
        gate.complete();
      });
    });

    test('waits for a task that finishes within the drain', () async {
      await app.run(() async {
        final gate = Completer<void>();
        final started = Completer<void>();
        var finished = false;
        App.make<Schedule>()
            .call(() async {
              started.complete();
              await gate.future;
              finished = true;
            })
            .everyMinute()
            .runInBackground()
            .withoutOverlapping()
            .named('report');
        final scheduler = Scheduler(
          App.make<Schedule>(),
          environment: 'testing',
          lockStore: Cache.store('database'),
          clock: () => at,
        );
        final working = scheduler.work(tick: const Duration(milliseconds: 5));
        await started.future;
        scheduler.stop(drain: const Duration(minutes: 1));
        var returned = false;
        unawaited(working.then((_) => returned = true));
        await Future<void>.delayed(Duration.zero);
        expect(returned, isFalse, reason: 'work() waits for the task');
        gate.complete();
        await working;
        expect(finished, isTrue);
        expect(await overlapLock('report').currentOwner(), isNull);
      });
    });

    test('schedule:clear-cache releases left-behind overlap locks', () async {
      await app.run(() async {
        App.make<Schedule>()
            .call(() {})
            .everyMinute()
            .withoutOverlapping()
            .named('nightly');
        App.make<Schedule>().call(() {}).everyMinute().named('plain');
        final held = Cache.store('database')
            .lock('schedule:nightly:* * * * *', owner: 'killed');
        expect(await held.acquire(), isTrue);
        expect(await app.scheduler().clearCache(), ['nightly']);
        expect(await held.currentOwner(), isNull);
      });
    });
  });

  group('a task that throws before it runs', () {
    test('a throwing filter skips only its own task', () async {
      await app.run(() async {
        final schedule = App.make<Schedule>();
        schedule
            .call(() => ran.add('filtered'))
            .everyMinute()
            .when(() => throw StateError('query failed'))
            .named('filtered');
        schedule.call(() => ran.add('other')).everyMinute().named('other');
        final fake = Event.fake();
        final results = await app.scheduler().run(at);
        expect(results.first.skipped, 'error');
        expect(results.first.error, isStateError);
        expect(results.last.ran, isTrue);
        expect(ran, ['other']);
        expect(fake.dispatchedTimes<ScheduledTaskSkipped>(), 1);
        Event.restore();
      });
    });

    test('a throwing ScheduledTaskStarting listener does not leak the '
        'overlap lock', () async {
      await app.run(() async {
        Event.listen<ScheduledTaskStarting>((_) => throw StateError('no'));
        App.make<Schedule>()
            .call(() => ran.add('leaky'))
            .everyMinute()
            .withoutOverlapping()
            .named('leaky');
        final results = await app.scheduler().run(at);
        expect(results.single.ran, isTrue);
        expect(ran, ['leaky']);
        expect(await overlapLock('leaky').currentOwner(), isNull);
      });
    });
  });

  group('onOneServer', () {
    test(
      'keys on the run start: a slow server cannot drift a minute',
      () async {
        await app.run(() async {
          final schedule = App.make<Schedule>();
          schedule
              .call(() => ran.add('b'))
              .everyMinute()
              .onOneServer()
              .named('b');
          Scheduler server(DateTime now) => Scheduler(
            schedule,
            environment: 'testing',
            lockStore: Cache.store('database'),
            clock: () => now,
          );
          // Server 1 reaches B after a slow task carried it into 03:01.
          final one = server(at.add(const Duration(minutes: 1, seconds: 5)));
          final two = server(at);
          expect((await one.run(at)).single.ran, isTrue);
          expect((await two.run(at)).single.skipped, 'another server');
          expect(ran, ['b']);
        });
      },
    );

    test('unnamed jobs of one class are told apart', () async {
      await app.run(() async {
        final schedule = App.make<Schedule>();
        schedule.job(const Greet('a')).everyMinute().onOneServer();
        schedule.job(const Greet('b')).everyMinute().onOneServer();
        final results = await app.scheduler().run(at);
        expect(results.map((r) => r.ran), [true, true]);
        expect(ran, ['greet:a', 'greet:b']);
      });
    });

    test('an unnamed closure is refused', () async {
      await app.run(() async {
        App.make<Schedule>().call(() {}).everyMinute().onOneServer();
        final results = await app.scheduler().run(at);
        expect(results.single.error, isStateError);
      });
    });

    test('lock rows are reused from one day to the next', () async {
      await app.run(() async {
        App.make<Schedule>()
            .call(() {})
            .everyMinute()
            .onOneServer()
            .named('daily');
        final scheduler = app.scheduler();
        await scheduler.run(at);
        final rows = await DB.table('cache_locks').count();
        expect(rows, 1);
        for (var day = 1; day <= 3; day++) {
          await scheduler.run(at.add(Duration(days: day)));
        }
        expect(await DB.table('cache_locks').count(), rows);
      });
    });
  });
}
