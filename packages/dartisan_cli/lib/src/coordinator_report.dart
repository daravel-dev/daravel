/// The coordinator's state as a running server reports it on `/metrics`
/// (Prometheus text), read back for `coordinator:stats --url`.
final class CoordinatorReport {
  CoordinatorReport({
    required this.messages,
    required this.rejected,
    required this.inFlight,
    required this.inFlightPeak,
    required this.maxQueue,
    required this.calls,
  });

  /// Reads the `coordinator_*` series of a `/metrics` response.
  factory CoordinatorReport.parse(String metrics) {
    final scalars = <String, double>{};
    final buckets = <String, Map<double, double>>{};
    final counts = <String, double>{};
    final sums = <String, double>{};
    final timeouts = <String, double>{};
    final line = RegExp(r'^([a-z_]+)(?:\{([^}]*)\})?\s+(\S+)$');
    for (final raw in metrics.split('\n')) {
      final match = line.firstMatch(raw.trim());
      if (match == null || !match[1]!.startsWith('coordinator_')) {
        continue;
      }
      final name = match[1]!;
      final labels = _labels(match[2] ?? '');
      final value = double.tryParse(match[3]!) ?? 0;
      final service = labels['service'] ?? '';
      switch (name) {
        case 'coordinator_call_duration_seconds_bucket':
          final le = labels['le'];
          final bound = le == '+Inf' ? double.infinity : double.tryParse('$le');
          if (bound != null) {
            final series = buckets.putIfAbsent(service, () => {});
            // Workers report separately; add them up.
            series[bound] = (series[bound] ?? 0) + value;
          }
        case 'coordinator_call_duration_seconds_count':
          counts[service] = (counts[service] ?? 0) + value;
        case 'coordinator_call_duration_seconds_sum':
          sums[service] = (sums[service] ?? 0) + value;
        case 'coordinator_call_timeouts_total':
          timeouts[service] = (timeouts[service] ?? 0) + value;
        default:
          scalars[name] = (scalars[name] ?? 0) + value;
      }
    }
    return CoordinatorReport(
      messages: scalars['coordinator_messages_total']?.toInt() ?? 0,
      rejected: scalars['coordinator_rejected_total']?.toInt() ?? 0,
      inFlight: scalars['coordinator_in_flight']?.toInt() ?? 0,
      inFlightPeak: scalars['coordinator_in_flight_peak']?.toInt() ?? 0,
      maxQueue: scalars['coordinator_max_queue']?.toInt() ?? 0,
      calls: {
        for (final service in {...counts.keys, ...timeouts.keys})
          service: ServiceCalls(
            count: (counts[service] ?? 0).toInt(),
            sumSeconds: sums[service] ?? 0,
            timeouts: (timeouts[service] ?? 0).toInt(),
            buckets: buckets[service] ?? const {},
          ),
      },
    );
  }

  final int messages;
  final int rejected;
  final int inFlight;
  final int inFlightPeak;
  final int maxQueue;

  /// Round trips from the workers, by coordinator service. Empty with one
  /// isolate, where the coordinator answers in place.
  final Map<String, ServiceCalls> calls;

  /// A p99 above this is worth acting on: the coordinator's answers come
  /// from one event loop, and every request that rate limits or reads the
  /// process cache waits for it.
  static const Duration slowP99 = Duration(milliseconds: 2);

  /// What to do about it; empty when nothing needs doing.
  List<String> advice() => [
    if (rejected > 0)
      '$rejected call(s) were refused because $inFlight of $maxQueue '
          'pending calls filled the queue: move the busiest state off the '
          'coordinator (below), or run fewer isolates per process.',
    if (rejected == 0 && maxQueue > 0 && inFlightPeak * 2 >= maxQueue)
      'The queue reached $inFlightPeak of $maxQueue pending calls: close to '
          'refusing calls.',
    for (final MapEntry(key: service, value: stats) in calls.entries) ...[
      if (stats.timeouts > 0) '$service: ${stats.timeouts} call(s) timed out.',
      if ((stats.quantile(0.99) ?? 0) > slowP99.inMicroseconds / 1e6)
        '$service: p99 ${_ms(stats.quantile(0.99)!)}. ${_remedy(service)}',
    ],
  ];

  static String _remedy(String service) => switch (service) {
    'rateLimiter' =>
      'Back the rate limiter with the cache store '
          '(CACHE_LIMITER=database, or withRedis() for Redis).',
    'processCache' =>
      'Keep hot keys in each worker for a moment (CACHE_PROCESS_L1_TTL=1s) '
          'or move the cache to Redis (CACHE_STORE=redis with withRedis()).',
    _ =>
      'Move this state to a cluster store (withRedis()) or run fewer '
          'isolates per process.',
  };

  static String _ms(double seconds) => seconds.isInfinite
      ? 'over 1 s'
      : '≤ ${(seconds * 1000).toStringAsFixed(seconds < 0.001 ? 2 : 1)} ms';

  static Map<String, String> _labels(String text) => {
    for (final match in RegExp(r'(\w+)="((?:[^"\\]|\\.)*)"').allMatches(text))
      match[1]!: match[2]!,
  };

  /// The report as text, with [advice].
  String render() {
    final out = StringBuffer()
      ..writeln('Coordinator')
      ..writeln('  messages       $messages')
      ..writeln('  rejected       $rejected')
      ..writeln('  in flight      $inFlight (peak $inFlightPeak of $maxQueue)');
    if (calls.isEmpty) {
      out.writeln(
        '  No round trips recorded: one isolate (the coordinator answers in '
        'place), or no traffic yet.',
      );
    } else {
      out.writeln('Round trips by service');
      for (final MapEntry(key: service, value: stats) in calls.entries) {
        final p50 = stats.quantile(0.5);
        final p99 = stats.quantile(0.99);
        out.writeln(
          '  ${service.padRight(14)} ${'${stats.count}'.padLeft(9)} calls  '
          'p50 ${p50 == null ? '-' : _ms(p50)}  '
          'p99 ${p99 == null ? '-' : _ms(p99)}'
          '${stats.timeouts > 0 ? '  ${stats.timeouts} timed out' : ''}',
        );
      }
    }
    final todo = advice();
    out.writeln(todo.isEmpty ? 'No action needed.' : 'Advice');
    for (final item in todo) {
      out.writeln('  - $item');
    }
    return out.toString();
  }
}

/// One service's round trips: a Prometheus histogram.
final class ServiceCalls {
  const ServiceCalls({
    required this.count,
    required this.sumSeconds,
    required this.timeouts,
    required this.buckets,
  });

  final int count;
  final double sumSeconds;
  final int timeouts;

  /// Upper bound in seconds → calls at or below it (cumulative).
  final Map<double, double> buckets;

  /// The upper bound of the bucket holding quantile [q]; null without
  /// calls. A histogram only knows bounds, so this is "at most".
  double? quantile(double q) {
    if (count == 0 || buckets.isEmpty) {
      return null;
    }
    final target = q * count;
    final bounds = buckets.keys.toList()..sort();
    for (final bound in bounds) {
      if (buckets[bound]! >= target) {
        return bound;
      }
    }
    return double.infinity;
  }
}
