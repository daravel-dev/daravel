import 'dart:async';

import '../server/coordinator.dart';
import '../server/worker_reports.dart';

/// Told what a Pusher server does, per application (its id): for metrics,
/// dashboards and Pulse. Every method does nothing unless overridden, so an
/// observer implements only what it needs; none is awaited, and they run on
/// the server's hot paths, so they must be quick.
class PusherObserver {
  /// An observer that ignores everything.
  const PusherObserver();

  /// A client connected (after the quota and origin checks).
  void connectionOpened(String app) {}

  /// A connected client went away.
  void connectionClosed(String app) {}

  /// A connection joined [channel].
  void subscribed(String app, String channel) {}

  /// A connection left [channel].
  void unsubscribed(String app, String channel) {}

  /// A client sent a message.
  void received(String app) {}

  /// A frame went out to a client.
  void sent(String app) {}

  /// A frame was published to its channel's subscribers in every isolate
  /// (and the other servers), which took [took].
  void published(String app, Duration took) {}

  /// A connection, message or subscription was refused for [reason]
  /// (`connection_quota`, `rate_limit`, `client_event_rate`,
  /// `channel_limit`).
  void rejected(String app, String reason) {}

  /// The kind of [channel]: `presence`, `encrypted`, `private` or `public`.
  static String channelType(String channel) => switch (channel) {
    _ when channel.startsWith('presence-') => 'presence',
    _ when channel.startsWith('private-encrypted-') => 'encrypted',
    _ when channel.startsWith('private-') => 'private',
    _ => 'public',
  };
}

/// Several observers as one.
final class PusherObservers extends PusherObserver {
  /// [observers], told in order.
  const PusherObservers(this.observers);

  /// The observers.
  final List<PusherObserver> observers;

  @override
  void connectionOpened(String app) {
    for (final o in observers) {
      o.connectionOpened(app);
    }
  }

  @override
  void connectionClosed(String app) {
    for (final o in observers) {
      o.connectionClosed(app);
    }
  }

  @override
  void subscribed(String app, String channel) {
    for (final o in observers) {
      o.subscribed(app, channel);
    }
  }

  @override
  void unsubscribed(String app, String channel) {
    for (final o in observers) {
      o.unsubscribed(app, channel);
    }
  }

  @override
  void received(String app) {
    for (final o in observers) {
      o.received(app);
    }
  }

  @override
  void sent(String app) {
    for (final o in observers) {
      o.sent(app);
    }
  }

  @override
  void published(String app, Duration took) {
    for (final o in observers) {
      o.published(app, took);
    }
  }

  @override
  void rejected(String app, String reason) {
    for (final o in observers) {
      o.rejected(app, reason);
    }
  }
}

/// This isolate's Pusher activity by application, reported to the
/// coordinator as topic [topic] of `WorkerReports` every [interval] while
/// it has connections (`REVERB_PULSE_INGEST_INTERVAL`), for Pulse's
/// *Reverb* card and the Reverb dashboard.
final class ReverbStats extends PusherObserver {
  /// Stats sent through [channel] every [interval]; [worker] names this
  /// isolate (its debug name by default).
  ReverbStats(
    this.channel, {
    this.interval = const Duration(seconds: 15),
    String? worker,
  }) : _reports = WorkerReports(channel, worker: worker);

  /// The topic of the reports.
  static const String topic = 'reverb';

  /// The channel to the coordinator.
  final CoordinatorChannel channel;

  /// How often a report is sent while there are connections.
  final Duration interval;

  final WorkerReports _reports;
  final Map<String, _AppStats> _apps = {};
  Timer? _timer;

  _AppStats _of(String app) => _apps[app] ??= _AppStats();

  /// Open connections on this isolate, every application together.
  int get connections =>
      _apps.values.fold(0, (sum, stats) => sum + stats.connections);

  @override
  void connectionOpened(String app) {
    _of(app).connections++;
    _timer ??= Timer.periodic(interval, (_) => flush().ignore());
  }

  @override
  void connectionClosed(String app) {
    final stats = _of(app);
    if (stats.connections > 0) {
      stats.connections--;
    }
    if (connections == 0) {
      // One last report with the zero, then quiet until the next client.
      _timer?.cancel();
      _timer = null;
      flush().ignore();
    }
  }

  @override
  void subscribed(String app, String channel) {
    final channels = _of(app).channels;
    final type = PusherObserver.channelType(channel);
    channels[type] = (channels[type] ?? 0) + 1;
  }

  @override
  void unsubscribed(String app, String channel) {
    final channels = _of(app).channels;
    final type = PusherObserver.channelType(channel);
    final left = (channels[type] ?? 1) - 1;
    if (left <= 0) {
      channels.remove(type);
    } else {
      channels[type] = left;
    }
  }

  @override
  void received(String app) => _of(app).received++;

  @override
  void sent(String app) => _of(app).sent++;

  /// Fan-out samples kept per application between reports: enough for the
  /// percentiles, bounded when publishes come without connections (and so
  /// without reports).
  static const int maxSamples = 1000;

  @override
  void published(String app, Duration took) {
    final samples = _of(app).fanoutMicros;
    if (samples.length < maxSamples) {
      samples.add(took.inMicroseconds);
    }
  }

  @override
  void rejected(String app, String reason) {
    final rejected = _of(app).rejected;
    rejected[reason] = (rejected[reason] ?? 0) + 1;
  }

  /// This isolate's activity since the last [report], by application:
  /// `{connections, channels: {type: n}, received, sent, rejected:
  /// {reason: n}, fanout_p50_ms, fanout_p95_ms, at}`. Counts restart from
  /// zero after each report; connections and channels are the current ones.
  Map<String, Object?> report() {
    final out = <String, Object?>{
      for (final MapEntry(key: app, value: stats) in _apps.entries)
        app: stats.take(),
    };
    _apps.removeWhere(
      (_, stats) => stats.connections == 0 && stats.channels.isEmpty,
    );
    return out;
  }

  /// Sends [report] now.
  Future<void> flush() => _reports.publish(topic, {
    'apps': report(),
    'at': DateTime.now().toUtc().toIso8601String(),
  });

  /// Stops the timer (application shutdown).
  void close() {
    _timer?.cancel();
    _timer = null;
  }

  /// Every isolate's last report (`{worker: report}`), for Pulse and the
  /// dashboard.
  static Future<Map<String, Object?>> collect(CoordinatorChannel channel) =>
      WorkerReports(channel).collect(topic);
}

final class _AppStats {
  int connections = 0;
  final Map<String, int> channels = {};
  int received = 0;
  int sent = 0;
  final Map<String, int> rejected = {};
  final List<int> fanoutMicros = [];

  Map<String, Object?> take() {
    final fanout = [...fanoutMicros]..sort();
    double? at(double q) => fanout.isEmpty
        ? null
        : fanout[((fanout.length - 1) * q).round()] / 1000;
    final report = <String, Object?>{
      'connections': connections,
      'channels': {...channels},
      'received': received,
      'sent': sent,
      'rejected': {...rejected},
      'fanout_p50_ms': at(0.5),
      'fanout_p95_ms': at(0.95),
    };
    received = 0;
    sent = 0;
    rejected.clear();
    fanoutMicros.clear();
    return report;
  }
}
