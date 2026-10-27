import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../foundation/config.dart';
import '../foundation/env.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';
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

String _labelKey(Map<String, String> labels) {
  if (labels.isEmpty) {
    return '';
  }
  final keys = labels.keys.toList()..sort();
  return keys
      .map(
        (k) =>
            '$k="${labels[k]!.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"',
      )
      .join(',');
}

/// Monotonic counter.
final class Counter {
  Counter._(this.name, this.help);

  final String name;
  final String help;
  final Map<String, double> _values = <String, double>{};

  void inc([Map<String, String> labels = const {}, double by = 1]) {
    final key = _labelKey(labels);
    _values[key] = (_values[key] ?? 0) + by;
  }

  double value([Map<String, String> labels = const {}]) =>
      _values[_labelKey(labels)] ?? 0;
}

/// Value that goes up and down.
final class Gauge {
  Gauge._(this.name, this.help, this._collect);

  final String name;
  final String help;
  final double Function()? _collect;
  final Map<String, double> _values = <String, double>{};

  void set(double value, [Map<String, String> labels = const {}]) =>
      _values[_labelKey(labels)] = value;

  void inc([Map<String, String> labels = const {}, double by = 1]) {
    final key = _labelKey(labels);
    _values[key] = (_values[key] ?? 0) + by;
  }

  void dec([Map<String, String> labels = const {}, double by = 1]) =>
      inc(labels, -by);

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
final class Histogram {
  Histogram._(this.name, this.help, this.buckets);

  final String name;
  final String help;
  final List<double> buckets;
  final Map<String, _HistogramSeries> _series = {};

  void observe(double value, [Map<String, String> labels = const {}]) {
    final series = _series.putIfAbsent(
      _labelKey(labels),
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
  final Map<String, Counter> _counters = <String, Counter>{};
  final Map<String, Gauge> _gauges = <String, Gauge>{};
  final Map<String, Histogram> _histograms = <String, Histogram>{};

  Counter counter(String name, String help) =>
      _counters.putIfAbsent(name, () => Counter._(name, help));

  /// [collect] computes the value at render time (e.g. memory).
  Gauge gauge(String name, String help, {double Function()? collect}) =>
      _gauges.putIfAbsent(name, () => Gauge._(name, help, collect));

  Histogram histogram(
    String name,
    String help, {
    List<double> buckets = defaultBuckets,
  }) => _histograms.putIfAbsent(name, () => Histogram._(name, help, buckets));

  /// Plain-data view of every metric.
  Map<String, Object?> snapshot() => <String, Object?>{
    for (final c in _counters.values)
      c.name: <String, Object?>{
        'type': 'counter',
        'help': c.help,
        'series': Map<String, Object?>.of(c._values),
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

/// Coordinator service collecting worker snapshots (`process` scope).
final class MetricsService implements CoordinatorService {
  static const String serviceName = 'metrics';

  final Map<String, Map<String, Object?>> _snapshots = {};

  @override
  String get name => serviceName;

  @override
  Object? handle(String op, Map<String, Object?> args) {
    switch (op) {
      case 'publish':
        _snapshots[args['worker']! as String] =
            args['snapshot']! as Map<String, Object?>;
        return null;
      case 'collect':
        return MetricsRegistry.merge(_snapshots.values);
      default:
        throw CoordinatorException('Unknown metrics op [$op].');
    }
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{
    'workers': _snapshots.length,
  };
}

/// `METRICS_*` configuration.
final class MetricsConfig implements ConfigSection {
  const MetricsConfig({
    this.enabled = false,
    this.path = '/metrics',
    this.token,
  });

  factory MetricsConfig.fromEnv(Env env) => MetricsConfig(
    enabled: env.boolean('METRICS_ENABLED', false),
    path: env.string('METRICS_PATH', '/metrics'),
    token: env.maybeString('METRICS_TOKEN'),
  );

  final bool enabled;
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
  };
}

/// Framework metrics: HTTP, queue and process (BLUEPRINT_V2 §7.10.4).
final class AppMetrics {
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
      'Requests currently being handled.',
    );
    jobs = registry.counter('queue_jobs_total', 'Queue jobs by status.');
    shed = registry.counter(
      'http_requests_shed_total',
      'Requests refused with 503 by load shedding '
          '(HTTP_MAX_IN_FLIGHT, HTTP_MAX_QUEUE_DELAY).',
    );
    registry.gauge(
      'process_resident_memory_bytes',
      'Resident set size of the process.',
      collect: () => ProcessInfo.currentRss.toDouble(),
    );
  }

  final MetricsRegistry registry;

  /// Coordinator channel for cross-isolate aggregation (remote only).
  final CoordinatorChannel? channel;

  late final Counter requests;
  late final Histogram duration;
  late final Gauge inFlight;
  late final Counter jobs;
  late final Counter shed;

  String get _worker =>
      Isolate.current.debugName ?? '${Isolate.current.hashCode}';

  /// Exposition text: merged across workers under a supervisor.
  Future<String> render() async {
    final remote = channel;
    if (remote == null || !remote.isRemote) {
      return registry.render();
    }
    // RSS is per process: report it once, not once per worker.
    final own = registry.snapshot();
    await remote.call(MetricsService.serviceName, 'publish', {
      'worker': _worker,
      'snapshot': own,
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

  /// Publishes this worker's snapshot periodically (supervisor mode).
  Timer? startPublishing({Duration every = const Duration(seconds: 1)}) {
    final remote = channel;
    if (remote == null || !remote.isRemote) {
      return null;
    }
    return Timer.periodic(every, (_) {
      remote.call(MetricsService.serviceName, 'publish', {
        'worker': _worker,
        'snapshot': registry.snapshot(),
      }).ignore();
    });
  }
}

/// Records request count, latency and in-flight gauge. The `route` label is
/// the route pattern (`/users/{id}`), never the raw path, to bound
/// cardinality; unmatched requests use `unmatched`.
final class MetricsMiddleware implements Middleware {
  const MetricsMiddleware(this.metrics);

  final AppMetrics metrics;

  @override
  Future<Response> handle(Request request, Next next) async {
    final stopwatch = Stopwatch()..start();
    metrics.inFlight.inc();
    var status = 500;
    try {
      final response = await next(request);
      status = response.status;
      return response;
    } finally {
      metrics.inFlight.dec();
      final route = request.route?.path ?? 'unmatched';
      metrics.requests.inc({
        'method': request.method,
        'route': route,
        'status': '$status',
      });
      metrics.duration.observe(stopwatch.elapsedMicroseconds / 1e6, {
        'method': request.method,
        'route': route,
      });
    }
  }
}
