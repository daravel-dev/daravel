import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Ping extends Job {
  const Ping();
  static const String jobName_ = 'ping';
  @override
  String get jobName => jobName_;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async => pings++;
  static int pings = 0;
}

void main() {
  late Application app;
  final at = DateTime.utc(2026, 10, 24, 3, 0);

  setUp(() async {
    Ping.pings = 0;
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'sync',
        })
        .withJobs([JobDefinition(Ping.jobName_, (_) => const Ping())])
        .create();
    await app.boot();
  });

  tearDown(() => app.shutdown());

  test('fluent frequencies produce cron expressions', () {
    final schedule = Schedule();
    expect(schedule.call(() {}).daily().cron.expression, '0 0 * * *');
    expect(
      schedule.call(() {}).dailyAt('13:45').cron.expression,
      '45 13 * * *',
    );
    expect(
      schedule.call(() {}).everyFifteenMinutes().cron.expression,
      '*/15 * * * *',
    );
    expect(
      schedule.call(() {}).weeklyOn(DateTime.sunday, '02:00').cron.expression,
      '0 2 * * 0',
    );
    expect(
      schedule.call(() {}).weeklyOn(DateTime.monday).cron.expression,
      '0 0 * * 1',
    );
    expect(
      schedule.call(() {}).monthlyOn(15, '08:30').cron.expression,
      '30 8 15 * *',
    );
    expect(
      schedule.call(() {}).hourly().weekdays().cron.expression,
      '0 * * * 1-5',
    );
    expect(
      schedule.call(() {}).twiceDaily(1, 13).cron.expression,
      '0 1,13 * * *',
    );
    final task = schedule
        .call(() {})
        .dailyAt('10:00')
        .timezone(const Duration(hours: 8))
        .named('wib');
    // 10:00 at UTC+8 is 02:00 UTC.
    expect(task.isDue(DateTime.utc(2026, 10, 24, 2, 0)), isTrue);
    expect(task.isDue(DateTime.utc(2026, 10, 24, 10, 0)), isFalse);
    expect(
      task.nextRun(DateTime.utc(2026, 10, 24, 3)),
      DateTime.utc(2026, 10, 25, 2),
    );
    expect(task.name, 'wib');
    expect(schedule.tasks, hasLength(9));
  });

  test('IANA zones follow daylight saving time', () {
    final schedule = Schedule();
    final ny = schedule
        .call(() {})
        .dailyAt('09:00')
        .timezone('America/New_York');
    expect(ny.timezoneName, 'America/New_York');
    // 09:00 is 14:00 UTC in winter (EST) and 13:00 UTC in summer (EDT).
    expect(ny.isDue(DateTime.utc(2026, 1, 15, 14)), isTrue);
    expect(ny.isDue(DateTime.utc(2026, 1, 15, 13)), isFalse);
    expect(ny.isDue(DateTime.utc(2026, 7, 15, 13)), isTrue);
    expect(ny.isDue(DateTime.utc(2026, 7, 15, 14)), isFalse);
    // Clocks go forward on 2026-03-08: the next 09:00 is already EDT.
    expect(
      ny.nextRun(DateTime.utc(2026, 3, 7, 15)),
      DateTime.utc(2026, 3, 8, 13),
    );

    // Values below were checked against Laravel 12 (dragonmantank/cron-
    // expression on PHP DateTime). 02:30 does not exist that night: it
    // runs once, at 03:30 EDT (07:30 UTC).
    final gap = schedule
        .call(() {})
        .dailyAt('02:30')
        .timezone('America/New_York');
    expect(
      [
        for (var hour = 5; hour <= 9; hour++)
          gap.isDue(DateTime.utc(2026, 3, 8, hour, 30)),
      ],
      [false, false, true, false, false],
    );
    expect(
      gap.nextRun(DateTime.utc(2026, 3, 8, 3)),
      DateTime.utc(2026, 3, 8, 7, 30),
    );
    // 01:30 happens twice when the clocks go back on 2026-11-01: it runs
    // at both (05:30 and 06:30 UTC).
    final repeated = schedule
        .call(() {})
        .dailyAt('01:30')
        .timezone('America/New_York');
    expect(
      [
        for (var hour = 4; hour <= 7; hour++)
          repeated.isDue(DateTime.utc(2026, 11, 1, hour, 30)),
      ],
      [false, true, true, false],
    );
    expect(
      repeated.nextRun(DateTime.utc(2026, 11, 1, 5, 31)),
      DateTime.utc(2026, 11, 1, 6, 30),
    );
    final every30 = schedule
        .call(() {})
        .everyThirtyMinutes()
        .timezone('America/New_York');
    expect(every30.isDue(DateTime.utc(2026, 3, 8, 6, 30)), isTrue);
    expect(every30.isDue(DateTime.utc(2026, 3, 8, 7)), isTrue);

    final jakarta = schedule
        .call(() {})
        .dailyAt('07:00')
        .timezone('Asia/Jakarta');
    expect(jakarta.isDue(DateTime.utc(2026, 10, 24)), isTrue);
    expect(jakarta.timezoneOffset, const Duration(hours: 7));

    final fixed = schedule.call(() {}).timezone(const Duration(hours: -3));
    expect(fixed.timezoneName, '-03:00');
    expect(schedule.call(() {}).timezoneName, '+00:00');

    expect(
      () => schedule.call(() {}).timezone('Mars/Olympus_Mons'),
      throwsArgumentError,
    );
    // Alias names PHP accepts (not in the canonical-only data set).
    for (final alias in ['UTC', 'GMT', 'US/Eastern', 'Asia/Saigon']) {
      expect(schedule.call(() {}).timezone(alias).timezoneName, alias);
    }
    expect(
      schedule
          .call(() {})
          .dailyAt('09:00')
          .timezone('US/Eastern')
          .isDue(DateTime.utc(2026, 1, 15, 14)),
      isTrue,
    );
    expect(() => schedule.call(() {}).timezone(7), throwsArgumentError);
  });

  test('SCHEDULE_TIMEZONE is the zone of tasks without their own '
      "(Laravel's app.schedule_timezone)", () async {
    final zoned = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'SCHEDULE_TIMEZONE': 'Asia/Jakarta',
        })
        .withSchedule((schedule) {
          schedule.call(() {}).dailyAt('08:00').named('local');
          schedule
              .call(() {})
              .dailyAt('08:00')
              .timezone(Duration.zero)
              .named('utc');
        })
        .create();
    await zoned.boot();
    addTearDown(zoned.shutdown);
    final tasks = {
      for (final t in zoned.container.make<Schedule>().tasks) t.name: t,
    };
    expect(tasks['local']!.timezoneName, 'Asia/Jakarta');
    expect(tasks['local']!.isDue(DateTime.utc(2026, 10, 24, 1)), isTrue);
    expect(tasks['utc']!.isDue(DateTime.utc(2026, 10, 24, 8)), isTrue);
    // Without it, tasks stay in UTC.
    expect(app.container.make<Schedule>().timezone, isNull);
    expect(
      ScheduledTask.wallTime(DateTime.utc(2026, 7, 1, 12), 'America/New_York'),
      DateTime.utc(2026, 7, 1, 8),
    );
  });

  test('runs due tasks with hooks, filters, jobs and events', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      final log = <String>[];
      schedule
          .call(() => log.add('nightly'))
          .dailyAt('03:00')
          .before(() => log.add('before'))
          .after(() => log.add('after'))
          .onSuccess(() => log.add('ok'))
          .named('nightly');
      schedule
          .call(() => log.add('skipped'))
          .dailyAt('03:00')
          .when(() => false)
          .named('filtered');
      schedule.call(() => log.add('prod-only')).dailyAt('03:00').environments([
        'production',
      ]);
      schedule.call(() => log.add('later')).dailyAt('04:00');
      schedule
          .call(() => throw StateError('boom'))
          .everyMinute()
          .onFailure((e) => log.add('failed:$e'))
          .named('broken');
      schedule.job(const Ping()).everyMinute();

      final fake = Event.fake();
      final results = await app.scheduler().run(at);
      expect(results.map((r) => r.task.name), [
        'nightly',
        'filtered',
        'Closure',
        'broken',
        'Ping',
      ]);
      expect(results[0].ran, isTrue);
      expect(results[1].skipped, 'filter');
      expect(results[2].skipped, 'filter');
      expect(results[3].error, isA<StateError>());
      expect(results[4].ran, isTrue);
      expect(log, [
        'before',
        'nightly',
        'ok',
        'after',
        'failed:Bad state: boom',
      ]);
      expect(Ping.pings, 1);
      expect(fake.dispatchedTimes<ScheduledTaskStarting>(), 3);
      expect(
        fake.of<ScheduledTaskFinished>((e) => !e.succeeded).single.task,
        'broken',
      );
      expect(fake.dispatchedTimes<ScheduledTaskSkipped>(), 2);
      Event.restore();
    });
  });

  test('withoutOverlapping skips while the lock is held; onOneServer needs cluster scope', () async {
    await app.run(() async {
      final schedule = App.make<Schedule>();
      var runs = 0;
      schedule
          .call(() => runs++)
          .everyMinute()
          .withoutOverlapping()
          .named('slow');
      final scheduler = app.scheduler();
      // The overlap lock names the task and its expression.
      final lock = Cache.store('process')
          .lock('schedule:slow:* * * * *', owner: 'other');
      expect(await lock.acquire(), isTrue);
      final blocked = await scheduler.run(at);
      expect(blocked.single.skipped, 'overlap');
      expect(runs, 0);
      await lock.forceRelease();
      expect((await scheduler.run(at)).single.ran, isTrue);
      expect(runs, 1);
      // Lock is released after the run.
      expect(await lock.currentOwner(), isNull);

      schedule.call(() {}).everyMinute().onOneServer().named('single');
      await expectLater(
        () => scheduler.run(at),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  test(
    'an unnamed closure with withoutOverlapping is refused at run',
    () async {
      await app.run(() async {
        // Every unnamed closure is called `Closure`: they would share one
        // lock and the second one due in a minute would always be skipped.
        App.make<Schedule>().call(() {}).everyMinute().withoutOverlapping();
        await expectLater(app.scheduler().run(at), throwsStateError);
      });
    },
  );

  test('commands run through the command runner', () async {
    await app.run(() async {
      final calls = <String>[];
      App.make<Schedule>().command('cache:clear', const [
        'memory',
      ]).everyMinute();
      final scheduler = app.scheduler(
        commandRunner: (command, args) async {
          calls.add('$command ${args.join(' ')}');
          return 0;
        },
      );
      final result = (await scheduler.run(at)).single;
      expect(result.error, isNull);
      expect(calls, ['cache:clear memory']);
      expect(result.task.name, 'cache:clear memory');
    });
  });
}
