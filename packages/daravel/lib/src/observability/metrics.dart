import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../foundation/config.dart';
import '../foundation/env.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../logging/logger.dart';
import '../server/coordinator.dart';

/// Default histogram buckets in seconds (Prometheus client defaults).
const List<double> defaultBuckets = <double>[
  0.005,
  0.01,
  0.025,
  0.05,
  0.1,
  0.25,
  0.5,
  1,
  2.5,
  5,
  10,
];

/// A label value escaped for the exposition format.
String _escapeLabel(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n');

String _labelKey(Map<String, String> labels) {
  if (labels.isEmpty) {
    return '';
  }
  if (labels.length == 1) {
    final entry = labels.entries.first;
    return '${entry.key}="${_escapeLabel(entry.value)}"';
  }
  final keys = labels.keys.toList()..sort();
  return keys.map((k) => '$k="${_escapeLabel(labels[k]!)}"').join(',');
}

/// The series a metric counts new label sets in once it holds
/// [MetricsRegistry.maxSeries] series.
const String overflowSeries = 'overflow="true"';

/// The behaviour shared by [Counter], [Gauge] and [Histogram]: the series
/// limit and the change count [AppMetrics.startPublishing] reads.
abstract base class _Metric {
  _Metric(this.name, this.help, this._registry, [this._limited = true]);

  /// The metric's name.
  final String name;

  /// The metric's help text.
  final String help;

  final MetricsRegistry _registry;
  final bool _limited;

  int get _seriesCount;
  bool _hasSeries(String key);

  /// [key], or [overflowSeries] when [key] is a new series beyond the
  /// registry's limit (counted in `metrics_series_dropped_total`). An
  /// unbounded label (a raw path, a user id) then costs one series, not
  /// one per value, on every worker and on the coordinator.
  String _admit(String key) {
    _registry._changes++;
    final max = _registry.maxSeries;
    if (!_limited ||
        max <= 0 ||
        _seriesCount < max ||
        identical(key, overflowSeries) ||
        _hasSeries(key)) {
      return key;
    }
    _registry._dropped.inc({'metric': name});
    return overflowSeries;
  }
}

/// Monotonic counter.
final class Counter extends _Metric {
  Counter._(
    String name,
    String help,
    MetricsRegistry registry, {
    bool limited = true,
    this._collect,
  }) : super(name, help, registry, limited);

  final double Function()? _collect;
  final Map<String, double> _values = <String, double>{};

  @override
  int get _seriesCount => _values.length;

  @override
  bool _hasSeries(String key) => _values.containsKey(key);

  /// Adds [by] to the series of [labels].
  void inc([Map<String, String> labels = const {}, double by = 1]) =>
      _incKey(_labelKey(labels), by);

  void _incKey(String labelKey, [double by = 1]) {
    final key = _admit(labelKey);
    _values[key] = (_values[key] ?? 0) + by;
  }

  /// The value of the series of [labels].
  double value([Map<String, String> labels = const {}]) =>
      _values[_labelKey(labels)] ?? 0;
}

/// Value that goes up and down.
///
/// Under a supervisor the series of every worker are summed: give a gauge
/// that is not a total (a temperature, a configured limit) a `worker`
/// label, or read it per worker.
final class Gauge extends _Metric {
  Gauge._(super.name, super.help, super._registry, this._collect);

  final double Function()? _collect;
  final Map<String, double> _values = <String, double>{};

  @override
  int get _seriesCount => _values.length;

  @override
  bool _hasSeries(String key) => _values.containsKey(key);

  /// Sets the series of [labels] to [value].
  void set(double value, [Map<String, String> labels = const {}]) =>
      _values[_admit(_labelKey(labels))] = value;

  /// Adds [by] to the series of [labels].
  void inc([Map<String, String> labels = const {}, double by = 1]) =>
      _incKey(_labelKey(labels), by);

  void _incKey(String labelKey, double by) {
    final key = _admit(labelKey);
    _values[key] = (_values[key] ?? 0) + by;
  }

  /// Subtracts [by] from the series of [labels].
  void dec([Map<String, String> labels = const {}, double by = 1]) =>
      inc(labels, -by);

  /// The value of the series of [labels].
  double value([Map<String, String> labels = const {}]) =>
      _values[_labelKey(labels)] ?? 0;
}

final class _HistogramSeries {
  _HistogramSeries(int buckets) : counts = List<int>.filled(buckets, 0);
  final List<int> counts;
  double sum = 0;
  int count = 0;
}

/// Cumulative histogram with fixed buckets.
final class Histogram extends _Metric {
  Histogram._(super.name, super.help, super._registry, this.buckets);

  /// The bucket upper bounds.
  final List<double> buckets;
  final Map<String, _HistogramSeries> _series = {};

  @override
  int get _seriesCount => _series.length;

  @override
  bool _hasSeries(String key) => _series.containsKey(key);

  /// Records [value] in the series of [labels].
  void observe(double value, [Map<String, String> labels = const {}]) =>
      _observeKey(value, _labelKey(labels));

  void _observeKey(double value, String labelKey) {
    final series = _series.putIfAbsent(
      _admit(labelKey),
      () => _HistogramSeries(buckets.length),
    );
    for (var i = 0; i < buckets.length; i++) {
      if (value <= buckets[i]) {
        series.counts[i]++;
      }
    }
    series
      ..sum += value
      ..count += 1;
  }

  /// Observations recorded for [labels].
  int count([Map<String, String> labels = const {}]) =>
      _series[_labelKey(labels)]?.count ?? 0;
}

/// Counters, gauges and histograms rendered in Prometheus text format.
///
/// [snapshot] produces a plain (isolate-sendable) map so the supervisor can
/// merge the registries of every worker ([MetricsRegistry.render] of merged
/// snapshots).
final class MetricsRegistry {
  /// A registry keeping at most [maxSeries] series per metric (`0`: no
  /// limit); see [overflowSeries].
  MetricsRegistry({this.maxSeries = defaultMaxSeries});

  /// The default of [maxSeries] (`METRICS_MAX_SERIES`).
  static const int defaultMaxSeries = 10000;

  /// Series per metric beyond which new label sets are counted in
  /// [overflowSeries] (`0`: no limit).
  final int maxSeries;

  final Map<String, Counter> _counters = <String, Counter>{};
  final Map<String, Gauge> _gauges = <String, Gauge>{};
  final Map<String, Histogram> _histograms = <String, Histogram>{};

  /// Bumped on every update, so a worker publishes only when it changed.
  int _changes = 0;

  /// New series refused by [maxSeries], by metric name (bounded by the
  /// number of metrics, so itself unlimited).
  late final Counter _dropped = _counters.putIfAbsent(
    'metrics_series_dropped_total',
    () => Counter._(
      'metrics_series_dropped_total',
      'Updates counted in the overflow series because the metric reached '
          'METRICS_MAX_SERIES, by metric.',
      this,
      limited: false,
    ),
  );

  /// The counter [name], created on first use; [collect] reads its
  /// unlabelled value at render time (a count kept elsewhere).
  Counter counter(String name, String help, {double Function()? collect}) =>
      _counters.putIfAbsent(
        name,
        () => Counter._(name, help, this, collect: collect),
      );

  /// [collect] computes the value at render time (e.g. memory).
  Gauge gauge(String name, String help, {double Function()? collect}) =>
      _gauges.putIfAbsent(name, () => Gauge._(name, help, this, collect));

  /// The histogram [name], created on first use.
  Histogram histogram(
    String name,
    String help, {
    List<double> buckets = defaultBuckets,
  }) => _histograms.putIfAbsent(
    name,
    () => Histogram._(name, help, this, buckets),
  );

  /// Plain-data view of every metric.
  Map<String, Object?> snapshot() => <String, Object?>{
    for (final c in _counters.values)
      c.name: <String, Object?>{
        'type': 'counter',
        'help': c.help,
        'series': <String, Object?>{
          ...c._values,
          if (c._collect != null) '': c._collect(),
        },
      },
    for (final g in _gauges.values)
      g.name: <String, Object?>{
        'type': 'gauge',
        'help': g.help,
        'series': <String, Object?>{
          ...g._values,
          if (g._collect != null) '': g._collect(),
        },
      },
    for (final h in _histograms.values)
      h.name: <String, Object?>{
        'type': 'histogram',
        'help': h.help,
        'buckets': h.buckets,
        'series': <String, Object?>{
          for (final e in h._series.entries)
            e.key: <String, Object?>{
              'counts': List<int>.of(e.value.counts),
              'sum': e.value.sum,
              'count': e.value.count,
            },
        },
      },
  };

  /// Sums several snapshots (counters, gauges and histogram buckets).
  static Map<String, Object?> merge(Iterable<Map<String, Object?>> snapshots) {
    final result = <String, Map<String, Object?>>{};
    for (final snapshot in snapshots) {
      for (final entry in snapshot.entries) {
        final metric = entry.value! as Map<String, Object?>;
        final target = result.putIfAbsent(
          entry.key,
          () => <String, Object?>{
            'type': metric['type'],
            'help': metric['help'],
            if (metric['buckets'] != null) 'buckets': metric['buckets'],
            'series': <String, Object?>{},
          },
        );
        final series = target['series']! as Map<String, Object?>;
        for (final s in (metric['series']! as Map<String, Object?>).entries) {
          if (metric['type'] == 'histogram') {
            final incoming = s.value! as Map<String, Object?>;
            final existing = series[s.key] as Map<String, Object?>?;
            if (existing == null) {
              series[s.key] = <String, Object?>{
                'counts': List<int>.of(
                  (incoming['counts']! as List<Object?>).cast<int>(),
                ),
                'sum': incoming['sum'],
                'count': incoming['count'],
              };
            } else {
              final counts = existing['counts']! as List<int>;
              final add = (incoming['counts']! as List<Object?>).cast<int>();
              for (var i = 0; i < counts.length; i++) {
                counts[i] += add[i];
              }
              existing['sum'] =
                  (existing['sum']! as num) + (incoming['sum']! as num);
              existing['count'] =
                  (existing['count']! as int) + (incoming['count']! as int);
            }
          } else {
            series[s.key] = ((series[s.key] as num?) ?? 0) + (s.value! as num);
          }
        }
      }
    }
    return result;
  }

  /// Prometheus exposition format (text 0.0.4) of this registry.
  String render() => renderSnapshot(snapshot());

  /// Prometheus exposition format of a (merged) snapshot.
  static String renderSnapshot(Map<String, Object?> snapshot) {
    final buffer = StringBuffer();
    final names = snapshot.keys.toList()..sort();
    String fmt(Object? v) {
      final n = (v ?? 0) as num;
      return n == n.roundToDouble() && n.abs() < 1e15 ? '${n.toInt()}' : '$n';
    }

    String series(String name, String labels, [String extra = '']) {
      final all = [if (labels.isNotEmpty) labels, if (extra.isNotEmpty) extra];
      return all.isEmpty ? name : '$name{${all.join(',')}}';
    }

    for (final name in names) {
      final metric = snapshot[name]! as Map<String, Object?>;
      final type = metric['type']! as String;
      buffer
        ..writeln('# HELP $name ${metric['help']}')
        ..writeln('# TYPE $name $type');
      final data = metric['series']! as Map<String, Object?>;
      final keys = data.keys.toList()..sort();
      for (final labels in keys) {
        if (type == 'histogram') {
          final h = data[labels]! as Map<String, Object?>;
          final bounds = (metric['buckets']! as List<Object?>).cast<num>();
          final counts = (h['counts']! as List<Object?>).cast<int>();
          for (var i = 0; i < bounds.length; i++) {
            buffer.writeln(
              '${series('${name}_bucket', labels, 'le="${fmt(bounds[i])}"')} ${counts[i]}',
            );
          }
          buffer
            ..writeln(
              '${series('${name}_bucket', labels, 'le="+Inf"')} ${h['count']}',
            )
            ..writeln('${series('${name}_sum', labels)} ${fmt(h['sum'])}')
            ..writeln('${series('${name}_count', labels)} ${h['count']}');
        } else {
          buffer.writeln('${series(name, labels)} ${fmt(data[labels])}');
        }
      }
    }
    return buffer.toString();
  }
}

/// [snapshot] as JSON text, which the VM shares between isolates instead of
/// deep-copying a map on every publish (ADR-031). A snapshot JSON cannot
/// hold (a NaN or infinite value) travels as the map itself.
Object _encodeSnapshot(Map<String, Object?> snapshot) {
  try {
    return jsonEncode(snapshot);
  } on JsonUnsupportedObjectError {
    return snapshot;
  }
}

/// The snapshot map of an [_encodeSnapshot] value.
Map<String, Object?> _decodeSnapshot(Object wire) => wire is String
    ? jsonDecode(wire) as Map<String, Object?>
    : wire as Map<String, Object?>;

/// Coordinator service collecting worker snapshots (`process` scope).
///
/// With [coordinatorStats] (the standard coordinator passes its own
/// `stats`), `collect` adds the coordinator's message counters, so a flood
/// of messages from the workers shows on `/metrics`.
///
/// A snapshot larger than [maxSnapshotBytes] is refused (the worker's
/// previous one stays), so one worker cannot make every scrape merge and
/// render megabytes on the supervisor's event loop. A worker that exits is
/// forgotten, so its last `http_requests_in_flight` is not served on.
final class MetricsService
    with PrioritizedService
    implements CoordinatorService, WorkerAwareService {
  /// Bulk: put off while lagging, refused while saturated.
  @override
  // One collect per scrape, answered at once: /metrics must work when the
  // coordinator is overloaded, which is when it is needed. Each worker's
  // periodic publish is what may wait or be dropped.
  CoordinatorPriority get priority => CoordinatorPriority.critical;

  @override
  Set<String> get bulkOperations => const {'publish'};

  /// A service merging the workers' metrics.
  MetricsService({
    this.coordinatorStats,
    this.maxSnapshotBytes = defaultMaxSnapshotBytes,
  });

  /// The coordinator service name.
  static const String serviceName = 'metrics';

  /// The default of [maxSnapshotBytes]: 16 MiB.
  static const int defaultMaxSnapshotBytes = 16 * 1024 * 1024;

  /// The largest snapshot (JSON characters) a worker may publish.
  final int maxSnapshotBytes;

  int _refused = 0;

  /// Adds the coordinator's own numbers to the output.
  final Map<String, Object?> Function()? coordinatorStats;

  /// [Coordinator.stats] as metrics, in the shape of
  /// [MetricsRegistry.snapshot]: `coordinator_messages_total` (rate it for
  /// messages per second), `coordinator_rejected_total` and
  /// `coordinator_in_flight`.
  static Map<String, Object?> coordinatorSnapshot(Map<String, Object?> stats) {
    Map<String, Object?> metric(
      String type,
      String help,
      String key,
    ) => <String, Object?>{
      'type': type,
      'help': help,
      'series': <String, Object?>{'': ((stats[key] ?? 0) as num).toDouble()},
    };
    Map<String, Object?> seconds(String help, String key) => <String, Object?>{
      'type': 'gauge',
      'help': help,
      'series': <String, Object?>{'': ((stats[key] ?? 0) as num) / 1000},
    };
    return <String, Object?>{
      'coordinator_messages_total': metric(
        'counter',
        'Messages the coordinator received from the workers.',
        'messages',
      ),
      'coordinator_rejected_total': metric(
        'counter',
        'Messages refused because the coordinator queue was full.',
        'rejected',
      ),
      'coordinator_in_flight': metric(
        'gauge',
        'Asynchronous coordinator calls not answered yet.',
        'in_flight',
      ),
      'coordinator_in_flight_peak': metric(
        'gauge',
        'The most asynchronous coordinator calls pending at once.',
        'in_flight_peak',
      ),
      'coordinator_max_queue': metric(
        'gauge',
        'Pending calls above which the coordinator refuses new ones.',
        'max_queue',
      ),
      'coordinator_expired_total': metric(
        'counter',
        'Requests dropped unanswered because their caller had stopped '
            'waiting.',
        'expired',
      ),
      'coordinator_queue_lag_seconds': seconds(
        'How long a message last waited in the coordinator event loop.',
        'queue_lag_ms',
      ),
      'coordinator_queue_lag_peak_seconds': seconds(
        'The longest a message waited in the coordinator event loop.',
        'queue_lag_peak_ms',
      ),
      // Blueprint #141 §6.6: a wait that was no queue (a busy host, a GC
      // pause, a late timer), never a reason to refuse work.
      'coordinator_starved_seconds': seconds(
        'How long the coordinator last waited for CPU with no queue behind.',
        'starved_ms',
      ),
      'coordinator_starved_peak_seconds': seconds(
        'The longest the coordinator waited for CPU with no queue behind.',
        'starved_peak_ms',
      ),
      // Blueprint #141 K1.
      'coordinator_health': <String, Object?>{
        'type': 'gauge',
        'help':
            'The coordinator state (1 for the current one: healthy, '
            'lagging, saturated).',
        'series': <String, Object?>{
          for (final s in CoordinatorState.values)
            'state="${s.name}"': s.name == stats['state'] ? 1.0 : 0.0,
        },
      },
      'coordinator_deferred': metric(
        'gauge',
        'Calls put off by the coordinator while lagging or saturated.',
        'deferred',
      ),
      'coordinator_deferred_peak': metric(
        'gauge',
        'The most calls put off at once.',
        'deferred_peak',
      ),
      'coordinator_shed_total': <String, Object?>{
        'type': 'counter',
        'help':
            'Calls refused while the coordinator was saturated, by service.',
        'series': <String, Object?>{
          for (final MapEntry(:key, :value)
              in ((stats['shed'] as Map<String, Object?>?) ?? const {}).entries)
            'service="$key"': (value! as num).toDouble(),
        },
      },
      'coordinator_served_total': <String, Object?>{
        'type': 'counter',
        'help': 'Calls the coordinator answered, by priority.',
        'series': <String, Object?>{
          for (final MapEntry(:key, :value)
              in ((stats['served_by_priority'] as Map<String, Object?>?) ??
                      const {})
                  .entries)
            'priority="$key"': (value! as num).toDouble(),
        },
      },
    };
  }

  /// The latest snapshot of each worker as it arrived: JSON text from
  /// [_encodeSnapshot] (or a plain map), decoded only on `collect`.
  final Map<String, Object> _snapshots = {};

  @override
  String get name => serviceName;

  @override
  Object? handle(String op, Map<String, Object?> args) {
    switch (op) {
      case 'publish':
        final snapshot = args['snapshot']!;
        if (snapshot is String && snapshot.length > maxSnapshotBytes) {
          _refused++;
          return false;
        }
        _snapshots[args['worker']! as String] = snapshot;
        return null;
      case 'collect':
        final stats = coordinatorStats;
        return <String, Object?>{
          // Decoded on a scrape (rare), not on every publish (each second).
          ...MetricsRegistry.merge(_snapshots.values.map(_decodeSnapshot)),
          if (stats != null) ...coordinatorSnapshot(stats()),
        };
      default:
        throw CoordinatorException('Unknown metrics op [$op].');
    }
  }

  @override
  void forgetWorker(String worker) => _snapshots.remove(worker);

  @override
  Map<String, Object?> stats() => <String, Object?>{
    'workers': _snapshots.length,
    'refused': _refused,
  };
}

/// `METRICS_*` configuration.
final class MetricsConfig implements ConfigSection {
  /// Metrics settings; usually from `.env` (`METRICS_*`).
  const MetricsConfig({
    this.enabled = false,
    this.path = '/metrics',
    this.token,
    this.maxSeries = MetricsRegistry.defaultMaxSeries,
  });

  /// The settings in `METRICS_*`.
  factory MetricsConfig.fromEnv(Env env) => MetricsConfig(
    enabled: env.boolean('METRICS_ENABLED', false),
    path: env.string('METRICS_PATH', '/metrics'),
    token: env.maybeString('METRICS_TOKEN'),
    maxSeries: env.integer(
      'METRICS_MAX_SERIES',
      MetricsRegistry.defaultMaxSeries,
    ),
  );

  /// Series per metric and worker before new label sets are counted in
  /// [overflowSeries] (`METRICS_MAX_SERIES`, `0`: no limit).
  final int maxSeries;

  /// Whether `/metrics` is served.
  final bool enabled;

  /// The path it is served at.
  final String path;

  /// When set, `/metrics` requires `Authorization: Bearer <token>`.
  final String? token;

  @override
  String get key => 'metrics';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'enabled': enabled,
    'path': path,
    'protected': token != null,
    'max_series': maxSeries,
  };
}

/// Framework metrics: HTTP, queue and process (BLUEPRINT_V2 §7.10.4).
final class AppMetrics {
  /// The framework's metrics in [registry].
  AppMetrics(this.registry, {this.channel}) {
    requests = registry.counter(
      'http_requests_total',
      'HTTP requests by method, route and status.',
    );
    duration = registry.histogram(
      'http_request_duration_seconds',
      'HTTP request latency by method and route.',
    );
    inFlight = registry.gauge(
      'http_requests_in_flight',
      'Requests currently being handled, by worker isolate.',
    );
    jobs = registry.counter('queue_jobs_total', 'Queue jobs by status.');
    afterCommitPushFailures = registry.counter(
      'queue_after_commit_push_failures_total',
      'Jobs dispatched inside a transaction that could not be pushed after '
          'the commit, by connection (their locks were given back).',
    );
    shed = registry.counter(
      'http_requests_shed_total',
      'Requests refused with 503 by load shedding '
          '(HTTP_MAX_IN_FLIGHT, HTTP_MAX_QUEUE_DELAY), by worker isolate.',
    );
    slowClients = registry.counter(
      'realtime_slow_clients_total',
      'WebSockets and server-sent event streams closed because the client '
          'read too slowly, by transport and worker isolate.',
    );
    reverbRejected = registry.counter(
      'reverb_rejected_total',
      'Pusher connections, messages and subscriptions refused, by reason '
          '(connection_quota, rate_limit, client_event_rate, channel_limit).',
    );
    reverbRateLimited = registry.counter(
      'reverb_rate_limited_total',
      'Pusher messages refused with 4301 Rate limit exceeded, by app.',
    );
    broadcastShed = registry.counter(
      'broadcast_shed_total',
      'Broadcasts dropped because the coordinator could not take them, by '
          'reason (overloaded, timeout).',
    );
    reverbConnections = registry.gauge(
      'reverb_connections',
      'Open Pusher connections, by app and worker isolate.',
    );
    reverbChannels = registry.gauge(
      'reverb_channels',
      'Pusher channel subscriptions, by app and channel type (public, '
          'private, presence, encrypted).',
    );
    reverbMessages = registry.counter(
      'reverb_messages_total',
      'Pusher messages, by app and direction (in: from clients, out: frames '
          'sent to clients).',
    );
    reverbFanout = registry.histogram(
      'reverb_fanout_seconds',
      'Time to hand one frame to every isolate (and the other servers) '
          'subscribed to its channel, by app.',
      buckets: coordinatorBuckets,
    );
    registry.counter(
      'log_lines_dropped_total',
      'Log lines dropped because the output (stdout, stderr, the log file) '
          'fell behind or failed.',
      collect: () => LogLineQueue.droppedTotal.toDouble(),
    );
    registry.gauge(
      'process_resident_memory_bytes',
      'Resident set size of the process.',
      collect: () => ProcessInfo.currentRss.toDouble(),
    );
    final remote = channel;
    if (remote is RemoteCoordinatorChannel) {
      // Under a supervisor every rate limit, process cache read and lock
      // is a round trip to the coordinator; its p99 says when to move
      // that state elsewhere (`dartisan coordinator:stats --url`).
      final calls = registry.histogram(
        'coordinator_call_duration_seconds',
        'Round trips from this worker to the coordinator, by service.',
        buckets: coordinatorBuckets,
      );
      final timeouts = registry.counter(
        'coordinator_call_timeouts_total',
        'Coordinator calls from this worker that timed out, by service.',
      );
      remote.onCallDuration = (String service, Duration roundTrip) =>
          calls.observe(roundTrip.inMicroseconds / 1e6, {'service': service});
      remote.onCallTimeout = (String service) =>
          timeouts.inc({'service': service});
      // Blueprint #141 K1: what the coordinator last said of its health,
      // and the calls this worker failed at once instead of waiting.
      final state = registry.gauge(
        'coordinator_state',
        'The coordinator state this worker last heard (1 for the current '
            'one: healthy, lagging, saturated).',
      );
      final shortCircuits = registry.counter(
        'coordinator_short_circuit_total',
        'Coordinator calls this worker failed at once because the '
            'coordinator was saturated, by service.',
      );
      void showState(CoordinatorState current) {
        for (final s in CoordinatorState.values) {
          state.set(s == current ? 1 : 0, {'state': s.name});
        }
      }

      showState(remote.coordinatorState);
      // Blueprint #141 K1b: bulk calls a full buffer dropped or refused
      // (worker reports, metrics snapshots and Horizon records are dropped
      // without telling their callers, so this is their only trace;
      // Review #153), and the window and buffer as they are now.
      final dropped = registry.counter(
        'coordinator_bulk_dropped_total',
        'Bulk calls this worker dropped or refused because its bulk buffer '
            'was full, by service and overflow policy.',
      );
      registry
        ..gauge(
          'coordinator_bulk_waiting',
          'Bulk calls of this worker waiting for credit.',
          collect: () => remote.bulkWaiting.toDouble(),
        )
        ..gauge(
          'coordinator_bulk_in_flight',
          'Bulk calls of this worker sent and not answered yet.',
          collect: () => remote.bulkInFlight.toDouble(),
        );
      remote
        ..onStateChange = showState
        ..onShortCircuit = (String service) {
          shortCircuits.inc({'service': service});
        }
        ..onBulkOverflow = (String service, BulkOverflow overflow) {
          dropped.inc({'service': service, 'overflow': overflow.name});
        };
    }
  }

  /// Buckets of `coordinator_call_duration_seconds`: a call answered in
  /// place takes tens of microseconds, a queued one milliseconds.
  static const List<double> coordinatorBuckets = <double>[
    0.0001,
    0.00025,
    0.0005,
    0.001,
    0.0025,
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    1,
  ];

  /// The registry holding the metrics.
  final MetricsRegistry registry;

  /// Coordinator channel for cross-isolate aggregation (remote only).
  final CoordinatorChannel? channel;

  /// Requests by method, route and status.
  late final Counter requests;

  /// Request durations.
  late final Histogram duration;

  /// Requests in progress.
  late final Gauge inFlight;

  /// Jobs by outcome.
  late final Counter jobs;

  /// Jobs a transaction dispatched that could not be pushed after commit.
  late final Counter afterCommitPushFailures;

  /// Requests shed under load.
  late final Counter shed;

  /// Realtime clients closed for reading too slowly.
  late final Counter slowClients;

  /// Pusher connections, messages and subscriptions refused.
  late final Counter reverbRejected;

  /// Pusher messages refused for a rate limit.
  late final Counter reverbRateLimited;

  /// Broadcasts dropped because the coordinator could not take them.
  late final Counter broadcastShed;

  /// Counts one broadcast dropped for [reason] (`overloaded`, `timeout`).
  void recordBroadcastShed(String reason) =>
      broadcastShed.inc({'reason': reason});

  /// Open Pusher connections (`reverb_connections{app,worker}`).
  late final Gauge reverbConnections;

  /// Channel subscriptions (`reverb_channels{app,type}`).
  late final Gauge reverbChannels;

  /// Messages in and out (`reverb_messages_total{app,direction}`).
  late final Counter reverbMessages;

  /// Fan-out time of one frame (`reverb_fanout_seconds{app}`).
  late final Histogram reverbFanout;

  /// Counts [delta] (1 or -1) open connections of [app] on this worker.
  void recordReverbConnection(String app, int delta) =>
      reverbConnections.inc({'app': app, 'worker': _worker}, delta.toDouble());

  /// Counts [delta] (1 or -1) subscriptions of [app] to a channel of
  /// [type].
  void recordReverbSubscription(String app, String type, int delta) =>
      reverbChannels.inc({'app': app, 'type': type}, delta.toDouble());

  /// Counts one message of [app] in [direction] (`in`, `out`).
  void recordReverbMessage(String app, String direction) =>
      reverbMessages.inc({'app': app, 'direction': direction});

  /// Records the fan-out of one frame of [app].
  void recordReverbFanout(String app, Duration took) =>
      reverbFanout.observe(took.inMicroseconds / 1e6, {'app': app});

  /// The `worker` label of [inFlight] and [shed]: the isolate's name
  /// (`daravel-worker-N` under a supervisor, the same after a respawn, so
  /// there is one value per worker). Workers share the port, which spreads
  /// connections rather than requests, and this shows when one is busier.
  late final String _worker =
      Isolate.current.debugName ?? '${Isolate.current.hashCode}';

  /// The label key of `{'worker': _worker}`, built once.
  late final String _workerKey = _labelKey({'worker': _worker});

  /// The escaped `route` label of each route pattern (bounded by the route
  /// table, plus `unmatched`), so a request does not escape it again.
  final Map<String, String> _routeLabels = <String, String>{};

  /// HTTP methods recorded under their own name; any other token (which
  /// `dart:io` accepts and the kernel answers with 404/405) is `other`, so
  /// the `method` label stays bounded.
  static const Set<String> knownMethods = <String>{
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'OPTIONS',
  };

  /// The `method` label of [method]: itself when in [knownMethods],
  /// `other` otherwise.
  static String methodLabel(String method) =>
      knownMethods.contains(method) ? method : 'other';

  /// Counts one request refused by load shedding on this worker.
  void recordShed() => shed._incKey(_workerKey);

  /// Records one finished request (what [MetricsMiddleware] does).
  void recordRequest(String method, String route, int status, double seconds) {
    final routeLabel = _routeLabels[route] ??= _escapeLabel(route);
    final methodAndRoute =
        'method="${methodLabel(method)}",route="$routeLabel"';
    requests._incKey('$methodAndRoute,status="$status"');
    duration._observeKey(seconds, methodAndRoute);
  }

  /// Counts one realtime client of [transport] (`websocket`, `sse`) closed
  /// on this worker for reading too slowly.
  void recordSlowClient(String transport) =>
      slowClients.inc({'transport': transport, 'worker': _worker});

  /// Counts one refusal of the Pusher server of [app], for [reason]
  /// (`PusherServer.onRejected`); both rate limits also count in
  /// `reverb_rate_limited_total`.
  void recordReverbRejected(String reason, {String app = ''}) {
    reverbRejected.inc({'app': app, 'reason': reason});
    if (reason == 'rate_limit' || reason == 'client_event_rate') {
      reverbRateLimited.inc({'app': app});
    }
  }

  /// Exposition text: merged across workers under a supervisor.
  Future<String> render() async {
    final remote = channel;
    if (remote is LocalCoordinatorChannel) {
      // One isolate: the coordinator is in this one; add its counters.
      return MetricsRegistry.renderSnapshot(<String, Object?>{
        ...registry.snapshot(),
        ...MetricsService.coordinatorSnapshot(remote.coordinator.stats()),
      });
    }
    if (remote == null || !remote.isRemote) {
      return registry.render();
    }
    // RSS is per process: report it once, not once per worker.
    final own = registry.snapshot();
    await remote.call(MetricsService.serviceName, 'publish', {
      'worker': _worker,
      'snapshot': _encodeSnapshot(own),
    });
    final merged = await remote.call(
      MetricsService.serviceName,
      'collect',
      const {},
    );
    final result = Map<String, Object?>.of(merged! as Map<String, Object?>);
    if (own.containsKey('process_resident_memory_bytes')) {
      result['process_resident_memory_bytes'] =
          own['process_resident_memory_bytes'];
    }
    return MetricsRegistry.renderSnapshot(result);
  }

  /// Publishes this worker's snapshot periodically (supervisor mode): on
  /// a tick after a change, and on every [heartbeat]th tick regardless
  /// (gauges computed at render time change without an update). An idle
  /// worker therefore sends one snapshot per [heartbeat] ticks, not one
  /// per tick.
  Timer? startPublishing({
    Duration every = const Duration(seconds: 1),
    int heartbeat = 15,
  }) {
    final remote = channel;
    if (remote == null || !remote.isRemote) {
      return null;
    }
    int? published;
    var idleTicks = 0;
    return Timer.periodic(every, (_) {
      final changes = registry._changes;
      if (changes == published && ++idleTicks < heartbeat) {
        return;
      }
      published = changes;
      idleTicks = 0;
      remote
          .callBulk(
            MetricsService.serviceName,
            'publish',
            {
              'worker': _worker,
              'snapshot': _encodeSnapshot(registry.snapshot()),
            },
            // The next snapshot supersedes it.
            overflow: BulkOverflow.dropOldest,
          )
          .whenComplete(() {
            // The publish's own round trip (or timeout) is one update of
            // `coordinator_call_*`: alone, it is not worth a publish.
            if (registry._changes == changes + 1) {
              published = changes + 1;
            }
          })
          .ignore();
    });
  }
}

/// Records request count, latency and in-flight gauge. The `route` label is
/// the route pattern (`/users/{id}`), never the raw path, to bound
/// cardinality; unmatched requests use `unmatched`. The `method` label is
/// one of [AppMetrics.knownMethods] or `other`.
final class MetricsMiddleware implements Middleware {
  /// Counts every request in [metrics].
  const MetricsMiddleware(this.metrics);

  /// The metrics updated.
  final AppMetrics metrics;

  @override
  Future<Response> handle(Request request, Next next) async {
    final stopwatch = Stopwatch()..start();
    final inFlight = metrics.inFlight;
    final worker = metrics._workerKey;
    inFlight._incKey(worker, 1);
    var status = 500;
    try {
      final response = await next(request);
      status = response.status;
      return response;
    } finally {
      inFlight._incKey(worker, -1);
      metrics.recordRequest(
        request.method,
        request.route?.path ?? 'unmatched',
        status,
        stopwatch.elapsedMicroseconds / 1e6,
      );
    }
  }
}
