import 'dart:async';
import 'dart:math';

import 'package:daravel/daravel.dart';

/// The key of `reverb:restart`, in the queue's signal store
/// (`QUEUE_SIGNAL_STORE`), as `queue:restart`'s: epoch milliseconds.
const String reverbRestartKey = 'daravel:reverb:restart';

/// The application factory `reverb:start` serves: [createApp]'s
/// application with only its Pusher server under [path] (and
/// `/broadcasting/auth` when [auth]), the health probes and `/metrics`
/// ([Application.serveBroadcastingOnly]).
///
/// The closure captures [createApp] (a top-level function) and plain
/// values, so the supervisor can send it to its worker isolates.
ApplicationFactory reverbServer(
  ApplicationFactory createApp, {
  String path = '',
  bool auth = false,
  bool debug = false,
}) =>
    () =>
        createApp()
          ..serveBroadcastingOnly(path: path, auth: auth, debug: debug);

/// Asks every `reverb:start` isolate, in every process sharing the signal
/// store, to restart: `reverb:restart`. Returns false when the queue has
/// no signal store.
Future<bool> requestReverbRestart(Application app) async {
  final signals = app.container.make<QueueManager>().signalStore;
  if (signals == null) {
    return false;
  }
  await signals.store.put(
    reverbRestartKey,
    DateTime.now().toUtc().millisecondsSinceEpoch,
  );
  return true;
}

/// Watches [reverbRestartKey] for an isolate of `reverb:start`: it reads
/// the key when it starts, and each [poll] (wall clock) again; once the
/// key holds another value than at the start (and not none), it waits a
/// random moment within [spread], so the isolates do not all go at once,
/// and calls [Application.restart] (the connections closed over
/// `REVERB_DRAIN_SPREAD`, the worker spawned again).
///
/// The values are compared, not their times, as Laravel Reverb does: the
/// time comes from the clock of the machine that ran `reverb:restart`,
/// which a server sharing the signal store need not agree with.
final class ReverbRestartWatcher {
  /// A watcher of [app]'s signals.
  ReverbRestartWatcher(
    this.app,
    this.signals, {
    this.poll = const Duration(seconds: 1),
    this.spread = const Duration(seconds: 2),
    Random? random,
  }) : _random = random ?? Random();

  /// The application to restart.
  final Application app;

  /// The queue's signal store.
  final CacheStore signals;

  /// How often the key is read.
  final Duration poll;

  /// The most an isolate waits before it restarts.
  final Duration spread;

  final Random _random;
  Timer? _timer;
  Future<Object?>? _atStart;
  bool _reading = false;

  /// Whether it watches.
  bool get watching => _timer != null;

  /// Starts watching; the restart requested before (the key's value now)
  /// is ignored.
  void start() {
    _atStart ??= _read();
    _timer ??= Timer.periodic(poll, (_) => unawaited(_check()));
  }

  /// The key's value, or null when it cannot be read: the next value read
  /// is then taken as a request, as from a key that was never set.
  Future<Object?> _read() async {
    try {
      return await signals.get(reverbRestartKey);
    } on Object catch (error) {
      app.logger.debug('reverb:restart signal not readable: $error');
      return null;
    }
  }

  /// Stops watching (shutdown).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _check() async {
    if (_reading) {
      return;
    }
    _reading = true;
    try {
      final before = await _atStart;
      final Object? requested;
      try {
        requested = await signals.get(reverbRestartKey);
      } on Object catch (error) {
        // The store is down: try again at the next poll.
        app.logger.debug('reverb:restart signal not readable: $error');
        return;
      }
      if (requested == null || requested == before || !watching) {
        return;
      }
      stop();
      final wait = spread.inMilliseconds <= 0
          ? Duration.zero
          : Duration(milliseconds: _random.nextInt(spread.inMilliseconds));
      app.logger.info(
        'reverb:restart requested; restarting in ${wait.inMilliseconds} ms.',
      );
      await Future<void>.delayed(wait);
      try {
        await app.restart();
      } on Object catch (error) {
        // Not restarted: keep watching, and try again at the next poll
        // (the value still differs from the one at the start).
        app.logger.error('reverb:restart failed: $error');
        _timer ??= Timer.periodic(poll, (_) => unawaited(_check()));
      }
    } finally {
      _reading = false;
    }
  }
}
