/// The `reverb_*` series of a `/metrics` response (Prometheus text): what
/// `reverb:stats` prints and the `/reverb` dashboard shows.
final class ReverbReport {
  /// A report.
  const ReverbReport({
    required this.connections,
    required this.channels,
    required this.messages,
    required this.rejected,
    this.rateLimited = const {},
    this.fanout = const {},
    this.slowClients = 0,
  });

  /// Reads the `reverb_*` series (and `realtime_slow_clients_total`) of
  /// Prometheus text; every worker isolate's series are added up.
  factory ReverbReport.parse(String metrics) {
    final connections = <String, Map<String, int>>{};
    final channels = <String, Map<String, int>>{};
    final messages = <String, Map<String, int>>{};
    final rejected = <String, int>{};
    final rateLimited = <String, int>{};
    final buckets = <String, Map<double, double>>{};
    var slowClients = 0;
    final line = RegExp(r'^([a-z_]+)(?:\{([^}]*)\})?\s+(\S+)$');
    final label = RegExp(r'([a-z_]+)="((?:[^"\\]|\\.)*)"');
    void add(Map<String, Map<String, int>> into, String a, String b, int n) {
      final row = into.putIfAbsent(a, () => {});
      row[b] = (row[b] ?? 0) + n;
    }

    for (final raw in metrics.split('\n')) {
      final match = line.firstMatch(raw.trim());
      final name = match?[1];
      if (match == null ||
          name == null ||
          !(name.startsWith('reverb_') ||
              name == 'realtime_slow_clients_total')) {
        continue;
      }
      final labels = {
        for (final l in label.allMatches(match[2] ?? '')) l[1]!: l[2]!,
      };
      final number = double.tryParse(match[3]!) ?? 0;
      final value = number.round();
      final app = labels['app'] ?? '';
      switch (name) {
        case 'reverb_connections':
          add(connections, app, labels['worker'] ?? '', value);
        case 'reverb_channels':
          add(channels, app, labels['type'] ?? '', value);
        case 'reverb_messages_total':
          add(messages, app, labels['direction'] ?? '', value);
        case 'reverb_rejected_total':
          final reason = labels['reason'] ?? '';
          rejected[reason] = (rejected[reason] ?? 0) + value;
        case 'reverb_rate_limited_total':
          rateLimited[app] = (rateLimited[app] ?? 0) + value;
        case 'reverb_fanout_seconds_bucket':
          final le = labels['le'];
          final bound = le == '+Inf' ? double.infinity : double.tryParse('$le');
          if (bound != null) {
            final series = buckets.putIfAbsent(app, () => {});
            series[bound] = (series[bound] ?? 0) + number;
          }
        case 'realtime_slow_clients_total'
            when labels['transport'] == 'websocket':
          slowClients += value;
      }
    }
    return ReverbReport(
      connections: connections,
      channels: channels,
      messages: messages,
      rejected: rejected,
      rateLimited: rateLimited,
      fanout: {
        for (final MapEntry(key: app, value: series) in buckets.entries)
          app: ?_quantiles(series),
      },
      slowClients: slowClients,
    );
  }

  /// p50 and p95 in milliseconds from cumulative histogram buckets: the
  /// upper bound of the bucket each falls in (null with no observation).
  static ({double p50, double p95, int count})? _quantiles(
    Map<double, double> series,
  ) {
    final bounds = series.keys.toList()..sort();
    final total =
        series[double.infinity] ?? (bounds.isEmpty ? 0 : series[bounds.last]!);
    if (total <= 0) {
      return null;
    }
    double at(double q) {
      for (final bound in bounds) {
        if (series[bound]! >= q * total) {
          return bound.isInfinite
              ? bounds[bounds.length - 2] * 1000
              : bound * 1000;
        }
      }
      return bounds.last * 1000;
    }

    return (p50: at(0.5), p95: at(0.95), count: total.round());
  }

  /// Open connections, by app and worker isolate.
  final Map<String, Map<String, int>> connections;

  /// Subscriptions, by app and channel type.
  final Map<String, Map<String, int>> channels;

  /// Messages since the server started, by app and direction (`in`,
  /// `out`).
  final Map<String, Map<String, int>> messages;

  /// Refusals since the server started, by reason.
  final Map<String, int> rejected;

  /// Messages refused with `4301`, by app.
  final Map<String, int> rateLimited;

  /// Fan-out time (one frame to every subscribed isolate) by app: p50 and
  /// p95 in milliseconds, bucket bounds, and the frames counted.
  final Map<String, ({double p50, double p95, int count})> fanout;

  /// WebSocket clients closed for reading too slowly (`4100`).
  final int slowClients;

  /// Every app the report names.
  List<String> get apps =>
      {...connections.keys, ...channels.keys, ...messages.keys}.toList()
        ..sort();

  /// Open connections of [app], every isolate together.
  int connectionsOf(String app) =>
      connections[app]?.values.fold<int>(0, (a, b) => a + b) ?? 0;

  /// Open connections by worker isolate, every app together.
  Map<String, int> get workers {
    final out = <String, int>{};
    for (final byWorker in connections.values) {
      for (final MapEntry(:key, :value) in byWorker.entries) {
        out[key] = (out[key] ?? 0) + value;
      }
    }
    return out;
  }

  /// As JSON (`reverb:stats --json`, `GET /reverb/api/stats`).
  Map<String, Object?> toJson() => {
    'apps': {
      for (final app in apps)
        app: {
          'connections': connectionsOf(app),
          'workers': connections[app] ?? const <String, int>{},
          'channels': channels[app] ?? const <String, int>{},
          'messages_in': messages[app]?['in'] ?? 0,
          'messages_out': messages[app]?['out'] ?? 0,
          'rate_limited': rateLimited[app] ?? 0,
          if (fanout[app] case final f?)
            'fanout': {'p50_ms': f.p50, 'p95_ms': f.p95, 'count': f.count},
        },
    },
    'workers': workers,
    'rejected': rejected,
    'slow_clients': slowClients,
  };

  /// As the table `reverb:stats` prints.
  String table() {
    if (apps.isEmpty) {
      return 'No Pusher connections reported.\n';
    }
    final out = StringBuffer();
    for (final app in apps) {
      final kinds = channels[app] ?? const <String, int>{};
      out.writeln(
        'App $app: ${connectionsOf(app)} connections, '
        '${kinds.isEmpty ? 'no channels' : kinds.entries.map((e) => '${e.value} ${e.key}').join(', ')}, '
        '${messages[app]?['in'] ?? 0} messages in, '
        '${messages[app]?['out'] ?? 0} out',
      );
      final workers =
          (connections[app] ?? const <String, int>{}).entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      for (final worker in workers) {
        out.writeln('  ${worker.key.padRight(20)} ${worker.value}');
      }
    }
    if (rejected.isNotEmpty) {
      out.writeln(
        'Refused: ${rejected.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
      );
    }
    return out.toString();
  }
}
