import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:timezone/timezone.dart' as tz;

import '../foundation/clock.dart';

import '../cache/cache.dart';
import '../events/events.dart';
import '../foundation/exceptions.dart';
import '../logging/logger.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';
import 'cron.dart';

/// Runs a console command by name (wired by the CLI runner).
typedef ScheduleCommandRunner = Future<int> Function(
  String command,
  List<String> args,
);

/// What a scheduled task does.
sealed class ScheduledAction {
  /// Actions are usually const.
  const ScheduledAction();
}

/// Runs a Dart callback.
final class CallbackAction extends ScheduledAction {
  /// Runs [callback].
  const CallbackAction(this.callback);

  /// The callback run.
  final FutureOr<void> Function() callback;
}

/// Pushes a job onto the queue.
final class JobAction extends ScheduledAction {
  /// Pushes [job] onto [queue] of [connection].
  const JobAction(this.job, {this.queue, this.connection});

  /// The job pushed.
  final Job job;

  /// The queue; the job's own when null.
  final String? queue;

  /// The connection; the job's own when null.
  final String? connection;
}

/// Runs a `dartisan` command.
final class CommandAction extends ScheduledAction {
  /// Runs [command] with [args].
  const CommandAction(this.command, this.args);

  /// The command name.
  final String command;

  /// Its arguments.
  final List<String> args;
}

/// Runs a program.
final class ExecAction extends ScheduledAction {
  /// Runs [executable] with [args].
  const ExecAction(this.executable, this.args);

  /// The program.
  final String executable;

  /// Its arguments.
  final List<String> args;
}

/// A task with its cron expression, filters and hooks (Laravel `Event`).
final class ScheduledTask {
  /// A task running [action]; `named()` sets its name.
  ScheduledTask(this.action, {this._name});

  /// What the task does.
  final ScheduledAction action;
  String? _name;
  CronExpression _cron = CronExpression.parse('* * * * *');
  Duration _offset = Duration.zero;
  tz.Location? _location;
  final List<FutureOr<bool> Function()> _filters = [];
  final List<FutureOr<bool> Function()> _rejects = [];
  final List<FutureOr<void> Function()> _before = [];
  final List<FutureOr<void> Function()> _after = [];
  final List<FutureOr<void> Function()> _onSuccess = [];
  final List<FutureOr<void> Function(Object error)> _onFailure = [];
  Duration? _withoutOverlapping;
  bool _onOneServer = false;
  List<String>? _environments;
  bool _background = false;

  /// Display name (defaults to a description of the action).
  String get name => _name ?? _describe();

  /// When the task is due.
  CronExpression get cron => _cron;

  /// The UTC offset in force now (a fixed offset, or the IANA zone's).
  Duration get timezoneOffset => _offsetAt(Clock.now().toUtc());

  /// The IANA zone name, or the fixed offset (`+07:00`).
  String get timezoneName => _location?.name ?? _formatOffset(_offset);

  Duration _offsetAt(DateTime utc) => switch (_location) {
    final tz.Location location =>
      location.timeZone(utc.millisecondsSinceEpoch).offset,
    null => _offset,
  };

  /// [utc] as wall-clock time in the task's zone (fields only).
  DateTime _wall(DateTime utc) => utc.toUtc().add(_offsetAt(utc.toUtc()));

  static String _formatOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    String two(int n) => n.toString().padLeft(2, '0');
    return '$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
  }

  /// [utc] as wall-clock time in [zone] (an IANA name or a `Duration`), for
  /// display (`schedule:list --timezone`).
  static DateTime wallTime(DateTime utc, Object zone) =>
      ScheduledTask(CallbackAction(() {})).timezone(zone)._wall(utc);

  /// Whether the task skips a run while the previous one is running.
  bool get overlapProtected => _withoutOverlapping != null;

  /// Whether only one server runs it.
  bool get singleServer => _onOneServer;

  /// Whether it runs without delaying the other due tasks.
  bool get runsInBackground => _background;

  String _describe() => switch (action) {
    CallbackAction() => 'Closure',
    JobAction(:final job) => job.displayName,
    CommandAction(:final command, :final args) => [command, ...args].join(' '),
    ExecAction(:final executable, :final args) => [
      executable,
      ...args,
    ].join(' '),
  };

  // ---------------------------------------------------------------------------
  // Frequency
  // ---------------------------------------------------------------------------

  /// Sets the display name (`->name()` in Laravel).
  ScheduledTask named(String value) => this.._name = value;

  /// Alias of [named].
  ScheduledTask description(String value) => named(value);

  /// Runs on the cron [expression].
  ScheduledTask cronExpression(String expression) =>
      this.._cron = CronExpression.parse(expression);

  /// Runs every minute.
  ScheduledTask everyMinute() => cronExpression('* * * * *');

  /// Runs every two minutes.
  ScheduledTask everyTwoMinutes() => cronExpression('*/2 * * * *');

  /// Runs every five minutes.
  ScheduledTask everyFiveMinutes() => cronExpression('*/5 * * * *');

  /// Runs every ten minutes.
  ScheduledTask everyTenMinutes() => cronExpression('*/10 * * * *');

  /// Runs every fifteen minutes.
  ScheduledTask everyFifteenMinutes() => cronExpression('*/15 * * * *');

  /// Runs every thirty minutes.
  ScheduledTask everyThirtyMinutes() => cronExpression('0,30 * * * *');

  /// Runs at the start of every hour.
  ScheduledTask hourly() => cronExpression('0 * * * *');

  /// Runs every hour at [minute].
  ScheduledTask hourlyAt(int minute) => cronExpression('$minute * * * *');

  /// Runs every two hours.
  ScheduledTask everyTwoHours() => cronExpression('0 */2 * * *');

  /// Runs every day at midnight.
  ScheduledTask daily() => cronExpression('0 0 * * *');

  /// `at('13:30')` — daily at a time (`HH:mm`).
  ScheduledTask at(String time) => dailyAt(time);

  /// Runs every day at [time] (`'13:00'`).
  ScheduledTask dailyAt(String time) {
    final (hour, minute) = _parseTime(time);
    return cronExpression('$minute $hour * * *');
  }

  /// Runs every day at the hours [first] and [second].
  ScheduledTask twiceDaily([int first = 1, int second = 13]) =>
      cronExpression('0 $first,$second * * *');

  /// Runs every Sunday at midnight.
  ScheduledTask weekly() => cronExpression('0 0 * * 0');

  /// [day] uses `DateTime.monday`..`DateTime.sunday`.
  ScheduledTask weeklyOn(int day, [String time = '0:00']) {
    final (hour, minute) = _parseTime(time);
    return cronExpression('$minute $hour * * ${day % 7}');
  }

  /// Runs on the first day of every month.
  ScheduledTask monthly() => cronExpression('0 0 1 * *');

  /// Runs every month on [day] at [time].
  ScheduledTask monthlyOn([int day = 1, String time = '0:00']) {
    final (hour, minute) = _parseTime(time);
    return cronExpression('$minute $hour $day * *');
  }

  /// Runs on the first day of every quarter.
  ScheduledTask quarterly() => cronExpression('0 0 1 1-12/3 *');

  /// Runs on January 1st.
  ScheduledTask yearly() => cronExpression('0 0 1 1 *');

  /// Only on Monday to Friday.
  ScheduledTask weekdays() => _appendWeekdays('1-5');

  /// Only on Saturday and Sunday.
  ScheduledTask weekends() => _appendWeekdays('0,6');

  /// Only on Sundays.
  ScheduledTask sundays() => _appendWeekdays('0');

  /// Only on Mondays.
  ScheduledTask mondays() => _appendWeekdays('1');

  /// Only on Fridays.
  ScheduledTask fridays() => _appendWeekdays('5');

  ScheduledTask _appendWeekdays(String days) {
    final fields = _cron.expression.split(RegExp(r'\s+'));
    fields[4] = days;
    return cronExpression(fields.join(' '));
  }

  /// The zone the cron expression is read in: an IANA name
  /// (`'Asia/Jakarta'`, `'America/New_York'`, daylight saving time
  /// included), as Laravel's `->timezone()`, or a fixed offset
  /// (`Duration(hours: 7)`).
  ScheduledTask timezone(Object zone) {
    switch (zone) {
      case final Duration offset:
        _offset = offset;
        _location = null;
      case final String name:
        _location = Clock.timeZone(name);
      default:
        throw ArgumentError.value(zone, 'zone', 'A zone name or a Duration');
    }
    return this;
  }

  // ---------------------------------------------------------------------------
  // Constraints
  // ---------------------------------------------------------------------------

  /// Runs only when [filter] returns true.
  ScheduledTask when(FutureOr<bool> Function() filter) =>
      this.._filters.add(filter);

  /// Skips the run when [filter] returns true.
  ScheduledTask skip(FutureOr<bool> Function() filter) =>
      this.._rejects.add(filter);

  /// Runs only between [start] and [end] (`HH:mm`, inclusive).
  ScheduledTask between(String start, String end) =>
      when(() => _inWindow(start, end, _wall(Clock.now())));

  /// Skips the run between [start] and [end] (`'22:00'`, `'06:00'`).
  ScheduledTask unlessBetween(String start, String end) =>
      skip(() => _inWindow(start, end, _wall(Clock.now())));

  /// Runs only in the environments [names].
  ScheduledTask environments(List<String> names) => this.._environments = names;

  /// Skips a run while the previous one still holds the lock.
  ScheduledTask withoutOverlapping({
    Duration expiresAfter = const Duration(hours: 24),
  }) => this.._withoutOverlapping = expiresAfter;

  /// Runs on one server only; requires a `cluster`-scope lock store.
  ScheduledTask onOneServer() => this.._onOneServer = true;

  /// Does not await the task (the scheduler loop moves on).
  ScheduledTask runInBackground() => this.._background = true;

  /// Calls [hook] before every run.
  ScheduledTask before(FutureOr<void> Function() hook) =>
      this.._before.add(hook);

  /// Calls [hook] after every run.
  ScheduledTask after(FutureOr<void> Function() hook) => this.._after.add(hook);

  /// Calls [hook] after a successful run.
  ScheduledTask onSuccess(FutureOr<void> Function() hook) =>
      this.._onSuccess.add(hook);

  /// Calls [hook] with the error after a failed run.
  ScheduledTask onFailure(FutureOr<void> Function(Object error) hook) =>
      this.._onFailure.add(hook);

  /// Whether the task is due at [utcNow] (minute precision).
  ///
  /// Daylight saving time works as in Laravel (PHP `DateTime`): a time
  /// skipped when the clocks go forward runs that much later (02:30 runs at
  /// 03:30), and a time repeated when they go back runs twice.
  bool isDue(DateTime utcNow) {
    final utc = utcNow.toUtc();
    if (_cron.matches(_wall(utc))) {
      return true;
    }
    if (_location == null) {
      return false;
    }
    // Shortly after a forward jump: was the local time `jump` earlier one
    // that did not exist? This (and nextRun's look-ahead) assumes zone
    // transitions are more than 3 hours apart and jumps at most 3 hours.
    // Current DST rules all fit (1 hour, 30 minutes on Lord Howe); a one-off
    // change such as Samoa's 24-hour jump in 2011 could misfire once.
    final now = _offsetAt(utc);
    final before = _offsetAt(utc.subtract(const Duration(hours: 3)));
    final jump = now - before;
    return jump > Duration.zero &&
        _offsetAt(utc.subtract(jump)) != now &&
        _cron.matches(utc.add(before));
  }

  /// Next run after [utcNow], in UTC (the earliest moment [isDue] holds).
  DateTime? nextRun(DateTime utcNow) {
    final utc = utcNow.toUtc();
    DateTime? best;
    // The offset now and the one just ahead cover a repeated hour (the
    // second 01:30 after the clocks go back).
    for (final offset in {
      _offsetAt(utc),
      _offsetAt(utc.add(const Duration(hours: 3))),
    }) {
      final wall = _cron.next(utc.add(offset));
      if (wall == null) {
        continue;
      }
      for (final guess in {offset, _offsetAt(wall.subtract(offset))}) {
        final candidate = wall.subtract(guess);
        if (candidate.isAfter(utc) &&
            isDue(candidate) &&
            (best == null || candidate.isBefore(best))) {
          best = candidate;
        }
      }
    }
    return best;
  }

  /// Whether the task's environment and filters let it run now.
  Future<bool> passesFilters(String environment) async {
    final envs = _environments;
    if (envs != null && !envs.contains(environment)) {
      return false;
    }
    for (final filter in _filters) {
      if (!await filter()) {
        return false;
      }
    }
    for (final reject in _rejects) {
      if (await reject()) {
        return false;
      }
    }
    return true;
  }

  static (int, int) _parseTime(String time) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time.trim());
    if (match == null) {
      throw ConfigException('Invalid time [$time]; expected HH:mm.');
    }
    return (int.parse(match[1]!), int.parse(match[2]!));
  }

  static bool _inWindow(String start, String end, DateTime now) {
    final (sh, sm) = _parseTime(start);
    final (eh, em) = _parseTime(end);
    final minutes = now.hour * 60 + now.minute;
    final s = sh * 60 + sm;
    final e = eh * 60 + em;
    return s <= e ? minutes >= s && minutes <= e : minutes >= s || minutes <= e;
  }
}

/// Declares scheduled tasks (`routes/console.dart`, Laravel 11 style).
final class Schedule {
  /// [timezone] (an IANA name or a `Duration`) is the zone of every task that
  /// does not name its own: `SCHEDULE_TIMEZONE`, Laravel's
  /// `app.schedule_timezone`. Without it, tasks run in UTC.
  Schedule({this.timezone});

  /// The time zone of the schedule's times; the app's by default.
  final Object? timezone;
  final List<ScheduledTask> _tasks = <ScheduledTask>[];

  /// The scheduled tasks.
  List<ScheduledTask> get tasks => List<ScheduledTask>.unmodifiable(_tasks);

  ScheduledTask _add(ScheduledAction action) {
    final task = ScheduledTask(action);
    if (timezone case final Object zone) {
      task.timezone(zone);
    }
    _tasks.add(task);
    return task;
  }

  /// Schedules [callback].
  ScheduledTask call(FutureOr<void> Function() callback) =>
      _add(CallbackAction(callback));

  /// Schedules pushing [job].
  ScheduledTask job(Job job, {String? queue, String? connection}) =>
      _add(JobAction(job, queue: queue, connection: connection));

  /// Schedules a `dartisan` command.
  ScheduledTask command(
    String command, [
    List<String> args = const <String>[],
  ]) => _add(CommandAction(command, args));

  /// Schedules running a program.
  ScheduledTask exec(
    String executable, [
    List<String> args = const <String>[],
  ]) => _add(ExecAction(executable, args));
}

/// Result of one task execution.
final class TaskRunResult {
  /// Whether [task] [ran], failed with [error], or was skipped.
  const TaskRunResult(this.task, {required this.ran, this.error, this.skipped});

  /// The task.
  final ScheduledTask task;

  /// Whether it ran.
  final bool ran;

  /// The error it failed with, or null.
  final Object? error;

  /// Reason when not run.
  final String? skipped;
}

/// Executes due tasks (`schedule:run`) or loops every minute
/// (`schedule:work`).
final class Scheduler {
  /// A scheduler running [schedule]'s due tasks in [environment].
  Scheduler(
    this.schedule, {
    required this.environment,
    this.events,
    this.queue,
    this.lockStore,
    this.commandRunner,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  /// The tasks.
  final Schedule schedule;

  /// The environment, for `environments(...)`.
  final String environment;

  /// Receives the scheduled task events.
  final EventDispatcher? events;

  /// Pushes the scheduled jobs.
  final QueueManager? queue;

  /// Lock store for `withoutOverlapping`/`onOneServer`.
  final CacheRepository? lockStore;

  /// Runs the scheduled commands.
  final ScheduleCommandRunner? commandRunner;

  /// Logs task failures.
  final Logger? logger;
  final DateTime Function() _clock;
  bool _stop = false;

  /// How long [work] waits for running tasks once stopped ([stop]).
  Duration _drain = defaultDrain;

  /// What [stop] gives running tasks to finish by default.
  static const Duration defaultDrain = Duration(seconds: 30);

  /// The minute runs of [work] and the task executions under way, each with
  /// the overlap lock it holds.
  final Set<Future<void>> _ticks = <Future<void>>{};
  final Map<Future<TaskRunResult>, Lock?> _running = {};

  /// How many task executions are under way (background ones included).
  int get runningTasks => _running.length;

  /// Runs every task due at [now] (default: current minute). A task whose
  /// filter, lock or listener throws is reported (`ScheduledTaskSkipped`
  /// with reason `error`, a [TaskRunResult] with the error) and the other
  /// tasks of the minute still run.
  Future<List<TaskRunResult>> run([DateTime? now]) async {
    final at = (now ?? _clock()).toUtc();
    final results = <TaskRunResult>[];
    for (final task in schedule.tasks) {
      if (_stop) {
        break;
      }
      if (!task.isDue(at)) {
        continue;
      }
      try {
        results.add(await runTask(task, at: at));
      } on Object catch (error, stackTrace) {
        logger?.error(
          'Scheduled task [${task.name}] could not start',
          error: error,
          stackTrace: stackTrace,
        );
        await _announce(ScheduledTaskSkipped(task.name, 'error'));
        results.add(
          TaskRunResult(task, ran: false, error: error, skipped: 'error'),
        );
      }
    }
    return results;
  }

  /// Runs one task regardless of its schedule (`schedule:test`), as part of
  /// the run started at [at] (default: now), which names the minute of an
  /// `onOneServer` lock.
  Future<TaskRunResult> runTask(ScheduledTask task, {DateTime? at}) async {
    if (!await task.passesFilters(environment)) {
      await _announce(ScheduledTaskSkipped(task.name, 'filter'));
      return TaskRunResult(task, ran: false, skipped: 'filter');
    }
    Lock? lock;
    if (task.overlapProtected || task.singleServer) {
      final store = lockStore;
      if (store == null) {
        throw const ConfigException(
          'withoutOverlapping/onOneServer need a cache lock store.',
        );
      }
      if (task.singleServer && store.scope != .cluster) {
        throw ConfigException(
          'onOneServer requires a cluster-scope lock store (database/redis); '
          '[${store.scope.name}] is not shared between servers.',
        );
      }
      if (task.action is CallbackAction && task._name == null) {
        // Every unnamed closure is called `Closure`: they would all share
        // one lock, and the second one due in a minute would always be
        // skipped. Laravel's CallbackEvent refuses both too.
        throw StateError(
          'A scheduled closure with withoutOverlapping() or onOneServer() '
          'needs a name (named(...)), or every closure shares one lock.',
        );
      }
      // Two locks, as Laravel's EventMutex and SchedulingMutex: the overlap
      // lock names the task and its expression (two tasks sharing a name on
      // different schedules do not block each other) and is released when
      // the run ends; the single-server lock names the minute and expires
      // on its own. A task with both used to take only the minute's lock,
      // which protected nothing against overlap.
      if (task.overlapProtected) {
        lock = store.lock(
          overlapLockName(task),
          ttl: task._withoutOverlapping ?? const Duration(hours: 24),
        );
        if (!await lock.acquire()) {
          await _announce(ScheduledTaskSkipped(task.name, 'overlap'));
          return TaskRunResult(task, ran: false, skipped: 'overlap');
        }
      }
      if (task.singleServer) {
        final Lock server;
        try {
          server = store.lock(
            serverLockName(task, at ?? _clock()),
            ttl: const Duration(hours: 1),
          );
          if (!await server.acquire()) {
            await lock?.release();
            await _announce(ScheduledTaskSkipped(task.name, 'another server'));
            return TaskRunResult(task, ran: false, skipped: 'another server');
          }
        } catch (_) {
          await lock?.release();
          rethrow;
        }
      }
    }
    final execution = _execute(task, releaseLock: lock);
    _running[execution] = lock;
    unawaited(execution.whenComplete(() => _running.remove(execution)));
    if (task.runsInBackground) {
      return TaskRunResult(task, ran: true);
    }
    return execution;
  }

  /// The overlap lock of [task] (`withoutOverlapping`): its name and cron
  /// expression, held while it runs.
  static String overlapLockName(ScheduledTask task) =>
      'schedule:${task.name}:${task.cron.expression}';

  /// The single-server lock of [task] (`onOneServer`) for the run started
  /// at [at], Laravel's `SchedulingMutex`: the task's expression and
  /// identity (its name; for an unnamed job, the job's name and data, so
  /// two jobs of one class do not share it), hashed, and the run's hour and
  /// minute. Keyed on the run's start, so a slow task before it cannot move
  /// it into the next minute on one server; without the date, so a day
  /// reuses the same 1 440 keys at most.
  static String serverLockName(ScheduledTask task, DateTime at) {
    final identity = switch (task.action) {
      JobAction(:final job) when task._name == null =>
        '${job.jobName}:${jsonEncode(job.toJson())}',
      _ => task.name,
    };
    final digest = sha1.convert(
      utf8.encode('${task.cron.expression}$identity'),
    );
    final t = at.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'schedule:$digest:${two(t.hour)}${two(t.minute)}';
  }

  /// Dispatches a scheduler event; a listener that throws is logged and
  /// cannot keep a lock held or a task from running.
  Future<void> _announce<E extends Object>(E event) async {
    try {
      await events?.dispatch(event);
    } on Object catch (error, stackTrace) {
      logger?.error(
        'A $E listener threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<TaskRunResult> _execute(
    ScheduledTask task, {
    Lock? releaseLock,
  }) async {
    final stopwatch = Stopwatch()..start();
    Object? error;
    try {
      await _announce(ScheduledTaskStarting(task.name));
      try {
        for (final hook in task._before) {
          await hook();
        }
        await _perform(task.action);
        for (final hook in task._onSuccess) {
          await hook();
        }
      } catch (e, stackTrace) {
        error = e;
        logger?.error(
          'Scheduled task [${task.name}] failed',
          error: e,
          stackTrace: stackTrace,
        );
        for (final hook in task._onFailure) {
          try {
            await hook(e);
          } catch (_) {
            // Hooks must not mask the original failure.
          }
        }
      } finally {
        for (final hook in task._after) {
          try {
            await hook();
          } catch (_) {
            // ignore
          }
        }
      }
      await _announce(
        ScheduledTaskFinished(task.name, stopwatch.elapsed, error: error),
      );
    } finally {
      try {
        await releaseLock?.release();
      } on Object catch (releaseError, stackTrace) {
        logger?.error(
          'Could not release the overlap lock of [${task.name}]',
          error: releaseError,
          stackTrace: stackTrace,
        );
      }
    }
    return TaskRunResult(task, ran: true, error: error);
  }

  Future<void> _perform(ScheduledAction action) async {
    switch (action) {
      case CallbackAction(:final callback):
        await callback();
      case JobAction(:final job, :final queue, :final connection):
        final manager = this.queue;
        if (manager == null) {
          throw const ConfigException('Scheduling jobs needs a queue manager.');
        }
        await manager.push(job, queue: queue, connection: connection);
      case CommandAction(:final command, :final args):
        final runner = commandRunner;
        if (runner == null) {
          throw const ConfigException(
            'Scheduling commands needs a command runner (run via dartisan).',
          );
        }
        final code = await runner(command, args);
        if (code != 0) {
          throw StateError('Command [$command] exited with code $code.');
        }
      case ExecAction(:final executable, :final args):
        final result = await Process.run(executable, args);
        if (result.exitCode != 0) {
          throw StateError(
            'Process [$executable] exited with code ${result.exitCode}: ${result.stderr}',
          );
        }
    }
  }

  /// Runs due tasks every minute until [stop]. A minute's run is not
  /// awaited before the next tick, so a task that takes minutes, or never
  /// completes, neither stops the scheduler nor skips the minutes in
  /// between (as Laravel's `schedule:work` starts a fresh `schedule:run`
  /// each minute); `withoutOverlapping` keeps such a task from running
  /// beside itself. Within a minute the tasks still run in order.
  ///
  /// Once stopped it waits for the tasks under way, background ones
  /// included, for the drain [stop] was given; tasks still running then
  /// have their overlap locks released (the process is about to end them)
  /// rather than holding them until they expire.
  Future<void> work({Duration? tick}) async {
    _stop = false;
    String? lastMinute;
    while (!_stop) {
      final now = _clock();
      final minute = _minuteKey(now);
      if (minute != lastMinute) {
        lastMinute = minute;
        final run = this
            .run(now)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stackTrace) => logger?.error(
                'Scheduler tick failed',
                error: error,
                stackTrace: stackTrace,
              ),
            );
        _ticks.add(run);
        unawaited(run.whenComplete(() => _ticks.remove(run)));
      }
      final wait =
          tick ??
          Duration(seconds: 60 - now.second, milliseconds: -now.millisecond);
      final wake = _wake = Completer<void>();
      await Future.any([
        Future<void>.delayed(
          wait.isNegative ? const Duration(seconds: 1) : wait,
        ),
        wake.future,
      ]);
      _wake = null;
    }
    await _drainRunning();
  }

  Future<void> _drainRunning() async {
    // The tick in progress first: it may still start tasks (it checks
    // [_stop] before each), then whatever runs.
    final pending = <Future<void>>[..._ticks, ..._running.keys];
    if (pending.isEmpty) {
      return;
    }
    var drained = true;
    await Future.wait(pending).timeout(
      _drain,
      onTimeout: () {
        drained = false;
        return const <void>[];
      },
    );
    if (drained && _running.isEmpty) {
      return;
    }
    for (final MapEntry(key: execution, value: lock)
        in _running.entries.toList()) {
      _running.remove(execution);
      if (lock == null) {
        continue;
      }
      logger?.warning(
        'A scheduled task still runs after the ${_drain.inSeconds}s drain; '
        'its overlap lock is released.',
      );
      try {
        await lock.release();
      } on Object catch (error, stackTrace) {
        logger?.error(
          'Could not release an overlap lock',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Completer<void>? _wake;

  /// Stops [work] after the running tick, without waiting for the next
  /// minute. [work] then waits up to [drain] for the tasks under way.
  void stop({Duration drain = defaultDrain}) {
    _stop = true;
    _drain = drain;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
  }

  /// Laravel's `schedule:clear-cache`: releases the overlap lock of every
  /// `withoutOverlapping` task, for one left behind by a scheduler that was
  /// killed while the task ran. Answers the names of the tasks.
  Future<List<String>> clearCache() async {
    final store = lockStore;
    if (store == null) {
      return const [];
    }
    final cleared = <String>[];
    for (final task in schedule.tasks) {
      if (!task.overlapProtected) {
        continue;
      }
      await store.lock(overlapLockName(task)).forceRelease();
      cleared.add(task.name);
    }
    return cleared;
  }

  static String _minuteKey(DateTime time) {
    final t = time.toUtc();
    return '${t.year}-${t.month}-${t.day}T${t.hour}:${t.minute}';
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}
