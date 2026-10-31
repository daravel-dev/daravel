import 'dart:async';
import 'dart:io' show Platform, stderr;
import 'dart:math' as math;

import '../foundation/container.dart';
import '../http/request.dart';
import '../logging/logger.dart';
import 'compute_pool.dart';

/// What [Concurrency.sync] and [Concurrency.fake] do to a zone.
final class ConcurrencyFake {
  ConcurrencyFake._();

  /// Tasks given to `run`.
  int ran = 0;

  /// Tasks given to `defer`.
  int deferred = 0;

  void assertRanCount(int expected) {
    if (ran != expected) {
      throw StateError('Expected $expected concurrent tasks, ran $ran.');
    }
  }

  void assertDeferredCount(int expected) {
    if (deferred != expected) {
      throw StateError('Expected $expected deferred tasks, got $deferred.');
    }
  }
}

/// Laravel's `Concurrency` facade, on a pool of warm worker isolates.
///
/// A task runs in another isolate, with its own memory. Facades do not work
/// there, because the worker has no application: pass the values a task needs
/// and return a result. A closure sends everything it captures, and an async
/// function's closures capture its whole scope, so a `Request` or a socket in
/// scope fails with an `ArgumentError`. Build tasks in a small function or
/// from static ones.
///
/// ```dart
/// final [users, orders] = await Concurrency.run<int>([
///   () => countLines(userFile),
///   () => countLines(orderFile),
/// ]);
/// ```
abstract final class Concurrency {
  /// Workers per isolate. With `serve --isolates=N` each has its own pool.
  static int get maxWorkers => _maxWorkers;

  static set maxWorkers(int value) {
    if (value < 1) {
      throw RangeError.range(value, 1, null, 'maxWorkers');
    }
    _maxWorkers = value;
  }

  static int _maxWorkers = math.min(Platform.numberOfProcessors, 4);

  static final ComputePool _pool = ComputePool(() => _maxWorkers);

  static final Object _zoneKey = Object();

  static ConcurrencyFake? get _fake =>
      Zone.current[_zoneKey] as ConcurrencyFake?;

  /// Runs [tasks] at once and returns their results in the same order. Every
  /// task runs; then the first failure, by position, is rethrown with its
  /// stack trace. A task past [timeout] fails with a `TimeoutException`.
  static Future<List<T>> run<T>(
    List<FutureOr<T> Function()> tasks, {
    int? concurrency,
    Duration? timeout,
  }) async {
    if (concurrency != null && concurrency < 1) {
      throw RangeError.range(concurrency, 1, null, 'concurrency');
    }
    final fake = _fake;
    if (fake != null) {
      fake.ran += tasks.length;
      return [for (final task in tasks) await task()];
    }
    final results = List<Object?>.filled(tasks.length, null);
    final failures = <int, (Object, StackTrace)>{};
    var next = 0;

    Future<void> lane() async {
      while (next < tasks.length) {
        final index = next++;
        try {
          results[index] = await _pool.run(tasks[index], timeout: timeout);
        } catch (error, stackTrace) {
          failures[index] = (error, stackTrace);
        }
      }
    }

    await Future.wait([
      for (
        var i = 0;
        i < math.min(concurrency ?? tasks.length, tasks.length);
        i++
      )
        lane(),
    ]);
    if (failures.isNotEmpty) {
      final first = failures.keys.reduce(math.min);
      final (error, stackTrace) = failures[first]!;
      Error.throwWithStackTrace(error, stackTrace);
    }
    return [for (final result in results) result as T];
  }

  /// Runs [tasks] on the workers after the response is sent, or soon outside
  /// a request. Failures are logged. For work that needs facades, use
  /// `Request.defer`, which stays in this isolate.
  static Future<void> defer(List<FutureOr<void> Function()> tasks) async {
    final fake = _fake;
    if (fake != null) {
      fake.deferred += tasks.length;
      for (final task in tasks) {
        await task();
      }
      return;
    }
    final container = Container.currentOrNull;
    final logger = container?.tryMake<Logger>();

    Future<void> send() async {
      await Future.wait([
        for (final task in tasks)
          _pool.run<void>(task).catchError((Object error, StackTrace stack) {
            if (logger == null) {
              stderr.writeln('Deferred task failed: $error');
            } else {
              logger.error(
                'Deferred task failed',
                error: error,
                stackTrace: stack,
              );
            }
          }),
      ]);
    }

    final request = container?.tryMake<Request>();
    if (request != null) {
      request.defer(send);
    } else {
      Timer.run(() => unawaited(send()));
    }
  }

  /// Runs [task] here when [payloadBytes] is below [threshold], where crossing
  /// to a worker costs more than it saves, and on a worker otherwise.
  static Future<R> runIfLarge<R>(
    int payloadBytes,
    FutureOr<R> Function() task, {
    int threshold = 65536,
  }) async {
    if (payloadBytes < threshold) {
      return task();
    }
    return (await run<R>([task])).single;
  }

  /// Laravel's `sync` driver: in [body], tasks run one by one in this isolate.
  /// `defer` runs them straight away, so a test can check the result.
  static Future<R> sync<R>(FutureOr<R> Function() body) async =>
      runZoned(() async => body(), zoneValues: {_zoneKey: ConcurrencyFake._()});

  /// [sync], and counts the tasks for [body] to assert on.
  static Future<R> fake<R>(FutureOr<R> Function(ConcurrencyFake fake) body) {
    final fake = ConcurrencyFake._();
    return runZoned(() async => body(fake), zoneValues: {_zoneKey: fake});
  }

  /// Stops the workers. `Application.shutdown` calls it; the next `run`
  /// starts again.
  static Future<void> shutdown() => _pool.shutdown();
}
