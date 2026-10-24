import 'dart:async';
import 'dart:io';

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
  const ScheduledAction();
}

final class CallbackAction extends ScheduledAction {
  const CallbackAction(this.callback);
  final FutureOr<void> Function() callback;
}

final class JobAction extends ScheduledAction {
  const JobAction(this.job, {this.queue, this.connection});
  final Job job;
  final String? queue;
  final String? connection;
}

final class CommandAction extends ScheduledAction {
  const CommandAction(this.command, this.args);
  final String command;
  final List<String> args;
}

final class ExecAction extends ScheduledAction {
  const ExecAction(this.executable, this.args);
  final String executable;
  final List<String> args;
}

/// A task with its cron expression, filters and hooks (Laravel `Event`).
final class ScheduledTask {
  ScheduledTask(this.action, {this._name});

  final ScheduledAction action;
  String? _name;
  CronExpression _cron = CronExpression.parse('* * * * *');
  Duration _offset = Duration.zero;
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

  CronExpression get cron => _cron;

  /// Fixed UTC offset applied before matching the cron expression.
  Duration get timezoneOffset => _offset;

  bool get overlapProtected => _withoutOverlapping != null;

  bool get singleServer => _onOneServer;

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

  ScheduledTask cronExpression(String expression) =>
      this.._cron = CronExpression.parse(expression);

  ScheduledTask everyMinute() => cronExpression('* * * * *');
  ScheduledTask everyTwoMinutes() => cronExpression('*/2 * * * *');
  ScheduledTask everyFiveMinutes() => cronExpression('*/5 * * * *');
  ScheduledTask everyTenMinutes() => cronExpression('*/10 * * * *');
  ScheduledTask everyFifteenMinutes() => cronExpression('*/15 * * * *');
  ScheduledTask everyThirtyMinutes() => cronExpression('0,30 * * * *');
  ScheduledTask hourly() => cronExpression('0 * * * *');
  ScheduledTask hourlyAt(int minute) => cronExpression('$minute * * * *');
  ScheduledTask everyTwoHours() => cronExpression('0 */2 * * *');
  ScheduledTask daily() => cronExpression('0 0 * * *');

  /// `at('13:30')` — daily at a time (`HH:mm`).
  ScheduledTask at(String time) => dailyAt(time);

  ScheduledTask dailyAt(String time) {
    final (hour, minute) = _parseTime(time);
    return cronExpression('$minute $hour * * *');
  }

  ScheduledTask twiceDaily([int first = 1, int second = 13]) =>
      cronExpression('0 $first,$second * * *');

  ScheduledTask weekly() => cronExpression('0 0 * * 0');

  /// [day] uses `DateTime.monday`..`DateTime.sunday`.
  ScheduledTask weeklyOn(int day, [String time = '0:00']) {
    final (hour, minute) = _parseTime(time);
    return cronExpression('$minute $hour * * ${day % 7}');
  }

  ScheduledTask monthly() => cronExpression('0 0 1 * *');

  ScheduledTask monthlyOn([int day = 1, String time = '0:00']) {
    final (hour, minute) = _parseTime(time);
    return cronExpression('$minute $hour $day * *');
  }

  ScheduledTask quarterly() => cronExpression('0 0 1 1-12/3 *');

  ScheduledTask yearly() => cronExpression('0 0 1 1 *');

  ScheduledTask weekdays() => _appendWeekdays('1-5');
  ScheduledTask weekends() => _appendWeekdays('0,6');
  ScheduledTask sundays() => _appendWeekdays('0');
  ScheduledTask mondays() => _appendWeekdays('1');
  ScheduledTask fridays() => _appendWeekdays('5');

  ScheduledTask _appendWeekdays(String days) {
    final fields = _cron.expression.split(RegExp(r'\s+'));
    fields[4] = days;
    return cronExpression(fields.join(' '));
  }

  /// Fixed offset from UTC (tier-1 limitation: no DST tables).
  ScheduledTask timezone(Duration offset) => this.._offset = offset;

  // ---------------------------------------------------------------------------
  // Constraints
  // ---------------------------------------------------------------------------

  ScheduledTask when(FutureOr<bool> Function() filter) =>
      this.._filters.add(filter);

  ScheduledTask skip(FutureOr<bool> Function() filter) =>
      this.._rejects.add(filter);

  /// Runs only between [start] and [end] (`HH:mm`, inclusive).
  ScheduledTask between(String start, String end) =>
      when(() => _inWindow(start, end, Clock.now().toUtc().add(_offset)));

  ScheduledTask unlessBetween(String start, String end) =>
      skip(() => _inWindow(start, end, Clock.now().toUtc().add(_offset)));

  ScheduledTask environments(List<String> names) => this.._environments = names;

  /// Skips a run while the previous one still holds the lock.
  ScheduledTask withoutOverlapping({
    Duration expiresAfter = const Duration(hours: 24),
  }) => this.._withoutOverlapping = expiresAfter;

  /// Runs on one server only; requires a `cluster`-scope lock store.
  ScheduledTask onOneServer() => this.._onOneServer = true;

  /// Does not await the task (the scheduler loop moves on).
  ScheduledTask runInBackground() => this.._background = true;

  ScheduledTask before(FutureOr<void> Function() hook) =>
      this.._before.add(hook);
  ScheduledTask after(FutureOr<void> Function() hook) => this.._after.add(hook);
  ScheduledTask onSuccess(FutureOr<void> Function() hook) =>
      this.._onSuccess.add(hook);
  ScheduledTask onFailure(FutureOr<void> Function(Object error) hook) =>
      this.._onFailure.add(hook);

  /// Whether the task is due at [utcNow] (minute precision).
  bool isDue(DateTime utcNow) => _cron.matches(utcNow.toUtc().add(_offset));

  /// Next run after [utcNow], in UTC.
  DateTime? nextRun(DateTime utcNow) =>
      _cron.next(utcNow.toUtc().add(_offset))?.subtract(_offset);

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
  final List<ScheduledTask> _tasks = <ScheduledTask>[];

  List<ScheduledTask> get tasks => List<ScheduledTask>.unmodifiable(_tasks);

  ScheduledTask _add(ScheduledAction action) {
    final task = ScheduledTask(action);
    _tasks.add(task);
    return task;
  }

  ScheduledTask call(FutureOr<void> Function() callback) =>
      _add(CallbackAction(callback));

  ScheduledTask job(Job job, {String? queue, String? connection}) =>
      _add(JobAction(job, queue: queue, connection: connection));

  ScheduledTask command(
    String command, [
    List<String> args = const <String>[],
  ]) => _add(CommandAction(command, args));

  ScheduledTask exec(
    String executable, [
    List<String> args = const <String>[],
  ]) => _add(ExecAction(executable, args));
}

/// Result of one task execution.
final class TaskRunResult {
  const TaskRunResult(this.task, {required this.ran, this.error, this.skipped});

  final ScheduledTask task;
  final bool ran;
  final Object? error;

  /// Reason when not run.
  final String? skipped;
}

/// Executes due tasks (`schedule:run`) or loops every minute
/// (`schedule:work`).
final class Scheduler {
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

  final Schedule schedule;
  final String environment;
  final EventDispatcher? events;
  final QueueManager? queue;

  /// Lock store for `withoutOverlapping`/`onOneServer`.
  final CacheRepository? lockStore;
  final ScheduleCommandRunner? commandRunner;
  final Logger? logger;
  final DateTime Function() _clock;
  bool _stop = false;

  /// Runs every task due at [now] (default: current minute).
  Future<List<TaskRunResult>> run([DateTime? now]) async {
    final at = (now ?? _clock()).toUtc();
    final results = <TaskRunResult>[];
    for (final task in schedule.tasks) {
      if (!task.isDue(at)) {
        continue;
      }
      results.add(await runTask(task));
    }
    return results;
  }

  /// Runs one task regardless of its schedule (`schedule:test`).
  Future<TaskRunResult> runTask(ScheduledTask task) async {
    if (!await task.passesFilters(environment)) {
      await events?.dispatch(ScheduledTaskSkipped(task.name, 'filter'));
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
      final ttl = task.singleServer && !task.overlapProtected
          ? const Duration(hours: 1)
          : (task._withoutOverlapping ?? const Duration(hours: 24));
      final key = task.singleServer
          ? 'schedule:${task.name}:${_minuteKey(_clock())}'
          : 'schedule:${task.name}';
      lock = store.lock(key, ttl: ttl);
      if (!await lock.acquire()) {
        final reason = task.singleServer ? 'another server' : 'overlap';
        await events?.dispatch(ScheduledTaskSkipped(task.name, reason));
        return TaskRunResult(task, ran: false, skipped: reason);
      }
    }
    final execution = _execute(
      task,
      releaseLock: task.singleServer ? null : lock,
    );
    if (task.runsInBackground) {
      unawaited(execution);
      return TaskRunResult(task, ran: true);
    }
    return execution;
  }

  Future<TaskRunResult> _execute(
    ScheduledTask task, {
    Lock? releaseLock,
  }) async {
    await events?.dispatch(ScheduledTaskStarting(task.name));
    final stopwatch = Stopwatch()..start();
    Object? error;
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
      await releaseLock?.release();
    }
    await events?.dispatch(
      ScheduledTaskFinished(task.name, stopwatch.elapsed, error: error),
    );
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

  /// Runs due tasks every minute until [stop].
  Future<void> work({Duration? tick}) async {
    _stop = false;
    String? lastMinute;
    while (!_stop) {
      final now = _clock();
      final minute = _minuteKey(now);
      if (minute != lastMinute) {
        lastMinute = minute;
        try {
          await run(now);
        } catch (error, stackTrace) {
          logger?.error(
            'Scheduler tick failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      final wait =
          tick ??
          Duration(seconds: 60 - now.second, milliseconds: -now.millisecond);
      await Future<void>.delayed(
        wait.isNegative ? const Duration(seconds: 1) : wait,
      );
    }
  }

  void stop() => _stop = true;

  static String _minuteKey(DateTime time) {
    final t = time.toUtc();
    return '${t.year}-${t.month}-${t.day}T${t.hour}:${t.minute}';
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}
