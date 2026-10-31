import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';

/// What one isolate saw: request counts by minute, and slow requests, slow
/// queries, exceptions and slow jobs grouped by what they have in common
/// (route, SQL, exception class and place, job name), in ten-minute
/// buckets kept for a day. Memory stays bounded: at most [maxGroups]
/// groups of a kind per bucket.
final class PulseRecorder {
  PulseRecorder({this.maxGroups = 50, String? worker})
    : worker =
          worker ?? Isolate.current.debugName ?? '${Isolate.current.hashCode}';

  /// How long recorded data is kept.
  static const Duration retention = Duration(hours: 24);

  /// The width of a bucket of grouped entries.
  static const Duration bucket = Duration(minutes: 10);

  /// The kinds of grouped entries.
  static const List<String> kinds = [
    'requests',
    'queries',
    'exceptions',
    'jobs',
    'storms',
    'pool_waits',
  ];

  final int maxGroups;

  /// This isolate's name (`daravel-worker-N` under a supervisor).
  final String worker;

  final DateTime startedAt = Clock.now();
  int _requestsTotal = 0;
  int _inFlight = 0;

  /// Minute → `[requests, server errors, slow requests, total µs]`.
  final SplayTreeMap<int, List<int>> _minutes = SplayTreeMap();

  /// Bucket start (ms) → kind → key → group.
  final SplayTreeMap<int, Map<String, Map<String, _Group>>> _buckets =
      SplayTreeMap();

  /// Called after each recording (the publisher schedules a send).
  void Function()? onRecord;

  int get requestsTotal => _requestsTotal;
  int get inFlight => _inFlight;

  void requestStarted() => _inFlight++;

  /// Counts a request; [slow] lists it under its route as well.
  void recordRequest({
    required String method,
    required String route,
    required int status,
    required Duration duration,
    required bool slow,
  }) {
    _inFlight = _inFlight > 0 ? _inFlight - 1 : 0;
    _requestsTotal++;
    final now = Clock.now();
    final minute = _minutes.putIfAbsent(
      now.millisecondsSinceEpoch ~/ 60000,
      () => [0, 0, 0, 0],
    );
    minute[0]++;
    if (status >= 500) {
      minute[1]++;
    }
    if (slow) {
      minute[2]++;
      _group('requests', '$method $route', now, duration, {
        'method': method,
        'route': route,
        'status': status,
      });
    }
    minute[3] += duration.inMicroseconds;
    _recorded(now);
  }

  /// Lists a slow query under its SQL (bindings are never kept).
  /// Lists a request that ran [statement] [count] times, or [total] queries
  /// in all; fast queries add up, so no threshold of time would catch it.
  void recordStorm({
    required String method,
    required String route,
    required String statement,
    required int count,
    required int total,
    required Duration duration,
  }) {
    final now = Clock.now();
    final text = _clip(statement, 1000);
    _group('storms', '$method $route|$text', now, duration, {
      'method': method,
      'route': route,
      'sql': text,
      'repeats': count,
      'queries': total,
    });
    _recorded(now);
  }

  /// Lists a query that waited [waited] for a connection.
  void recordPoolWait(String connection, Duration waited) {
    final now = Clock.now();
    _group('pool_waits', connection, now, waited, {'connection': connection});
    _recorded(now);
  }

  void recordQuery(String sql, String connection, Duration duration) {
    final now = Clock.now();
    final text = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    _group('queries', '$connection\u0000${_clip(text, 1000)}', now, duration, {
      'sql': _clip(text, 1000),
      'connection': connection,
    });
    _recorded(now);
  }

  /// Lists an exception under its class and the first frame of [stack].
  void recordException(Object error, StackTrace stack) {
    final now = Clock.now();
    final type = error.runtimeType.toString();
    final frames = stack.toString().trimRight().split('\n');
    final location = _location(frames);
    _group('exceptions', '$type\u0000$location', now, Duration.zero, {
      'class': type,
      'location': location,
      'message': _clip(_message(error), 300),
      'trace': frames.take(15).join('\n'),
    });
    _recorded(now);
  }

  /// Lists a slow or failed job under its name.
  void recordJob(
    String name,
    String queue,
    Duration duration, {
    bool failed = false,
  }) {
    final now = Clock.now();
    final group = _group('jobs', '$queue\u0000$name', now, duration, {
      'job': name,
      'queue': queue,
    });
    if (failed && group != null) {
      group.failed++;
    }
    _recorded(now);
  }

  /// What this isolate recorded, as sendable data for
  /// [PulseSnapshot.build] (and the coordinator, under a supervisor).
  Map<String, Object?> report() {
    _prune(Clock.now());
    return {
      'worker': worker,
      'started_at': startedAt.millisecondsSinceEpoch,
      'requests_total': _requestsTotal,
      'in_flight': _inFlight,
      'memory_bytes': ProcessInfo.currentRss,
      'reported_at': Clock.now().millisecondsSinceEpoch,
      'minutes': [
        for (final MapEntry(:key, :value) in _minutes.entries) [key, ...value],
      ],
      'buckets': [
        for (final MapEntry(:key, :value) in _buckets.entries)
          {
            'at': key,
            for (final MapEntry(key: kind, value: groups) in value.entries)
              kind: [for (final group in groups.values) group.toJson()],
          },
      ],
    };
  }

  _Group? _group(
    String kind,
    String key,
    DateTime now,
    Duration duration,
    Map<String, Object?> details,
  ) {
    final ms = now.millisecondsSinceEpoch;
    final start = ms - ms % bucket.inMilliseconds;
    final groups = _buckets
        .putIfAbsent(start, () => {})
        .putIfAbsent(kind, () => {});
    var group = groups[key];
    if (group == null) {
      if (groups.length >= maxGroups) {
        return null;
      }
      group = groups[key] = _Group(key);
    }
    return group..add(ms, duration, details);
  }

  void _recorded(DateTime now) {
    _prune(now);
    onRecord?.call();
  }

  void _prune(DateTime now) {
    final oldest = now.subtract(retention).millisecondsSinceEpoch;
    while (_minutes.isNotEmpty && _minutes.firstKey()! * 60000 < oldest) {
      _minutes.remove(_minutes.firstKey());
    }
    while (_buckets.isNotEmpty &&
        _buckets.firstKey()! + bucket.inMilliseconds <= oldest) {
      _buckets.remove(_buckets.firstKey());
    }
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  static String _message(Object error) {
    final text = error.toString();
    final type = error.runtimeType.toString();
    return text.startsWith('$type: ') ? text.substring(type.length + 2) : text;
  }

  /// The first frame in application code, else the first frame.
  static String _location(List<String> frames) {
    final pattern = RegExp(r'\((.+?:\d+)(?::\d+)?\)\s*$');
    String? first;
    for (final frame in frames) {
      final at = pattern.firstMatch(frame)?.group(1);
      if (at == null) {
        continue;
      }
      first ??= at;
      if (!at.startsWith('dart:') &&
          !at.startsWith('package:daravel/') &&
          !at.startsWith('package:daravel_pulse/')) {
        return at;
      }
    }
    return first ?? '';
  }
}

final class _Group {
  _Group(this.key);

  final String key;
  int count = 0;
  int failed = 0;
  double maxMs = 0;
  double totalMs = 0;
  int lastAt = 0;
  Map<String, Object?> details = const {};

  _Group add(int at, Duration duration, Map<String, Object?> latest) {
    final ms = duration.inMicroseconds / 1000;
    count++;
    totalMs += ms;
    if (ms > maxMs) {
      maxMs = ms;
    }
    if (at >= lastAt) {
      lastAt = at;
      details = latest;
    }
    return this;
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'count': count,
    'failed': failed,
    'max_ms': maxMs,
    'total_ms': totalMs,
    'last_at': lastAt,
    ...details,
  };
}

/// The dashboard's data: the reports of every isolate merged over a
/// window.
abstract final class PulseSnapshot {
  /// The windows the dashboard offers.
  static const Map<String, Duration> windows = {
    '1h': Duration(hours: 1),
    '6h': Duration(hours: 6),
    '24h': Duration(hours: 24),
  };

  /// The snapshot key of each kind of group.
  static const Map<String, String> _output = {
    'requests': 'slow_requests',
    'queries': 'slow_queries',
    'exceptions': 'exceptions',
    'jobs': 'jobs',
    'storms': 'query_storms',
    'pool_waits': 'pool_waits',
  };

  /// Merges [reports] over [window] ending at [now]: totals, a 60-point
  /// series, the top [limit] groups of each kind, and the workers.
  static Map<String, Object?> build(
    Iterable<Map<String, Object?>> reports, {
    required Duration window,
    required DateTime now,
    int limit = 10,
  }) {
    final end = now.millisecondsSinceEpoch;
    final from = end - window.inMilliseconds;
    final step = window.inMilliseconds ~/ 60;
    final series = [
      for (var i = 0; i < 60; i++) [from + i * step, 0, 0, 0],
    ];
    var requests = 0, errors = 0, slow = 0, micros = 0;
    final groups = {
      for (final kind in PulseRecorder.kinds)
        kind: <String, Map<String, Object?>>{},
    };
    final workers = <Map<String, Object?>>[];
    int? memory;
    for (final report in reports) {
      workers.add({
        'name': report['worker'],
        'started_at': report['started_at'],
        'requests_total': report['requests_total'],
        'in_flight': report['in_flight'],
        'reported_at': report['reported_at'],
      });
      // One process: every isolate reports the same resident memory.
      memory ??= report['memory_bytes'] as int?;
      for (final row in report['minutes']! as List<Object?>) {
        final minute = (row! as List<Object?>).cast<int>();
        final at = minute[0] * 60000;
        if (at + 60000 <= from || at > end) {
          continue;
        }
        requests += minute[1];
        errors += minute[2];
        slow += minute[3];
        micros += minute[4];
        final point = series[((at - from) ~/ step).clamp(0, 59)];
        point[1] += minute[1];
        point[2] += minute[2];
        point[3] += minute[3];
      }
      for (final bucket in report['buckets']! as List<Object?>) {
        final map = bucket! as Map<String, Object?>;
        final at = map['at']! as int;
        if (at + PulseRecorder.bucket.inMilliseconds <= from || at > end) {
          continue;
        }
        for (final kind in PulseRecorder.kinds) {
          for (final entry in (map[kind] as List<Object?>?) ?? const []) {
            _merge(groups[kind]!, entry! as Map<String, Object?>);
          }
        }
      }
    }
    workers.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return {
      'generated_at': end,
      'window_ms': window.inMilliseconds,
      'memory_bytes': memory,
      'workers': workers,
      'requests': {
        'total': requests,
        'errors': errors,
        'slow': slow,
        'avg_ms': requests == 0 ? 0 : micros / requests / 1000,
        'series': series,
      },
      for (final kind in PulseRecorder.kinds)
        _output[kind]!: _top(groups[kind]!.values, kind, limit),
    };
  }

  static void _merge(
    Map<String, Map<String, Object?>> into,
    Map<String, Object?> group,
  ) {
    final key = group['key']! as String;
    final existing = into[key];
    if (existing == null) {
      into[key] = Map.of(group);
      return;
    }
    final newer = (group['last_at']! as int) >= (existing['last_at']! as int);
    final merged = newer ? Map.of(group) : existing;
    merged
      ..['count'] = (existing['count']! as int) + (group['count']! as int)
      ..['failed'] = (existing['failed']! as int) + (group['failed']! as int)
      ..['total_ms'] =
          (existing['total_ms']! as num) + (group['total_ms']! as num)
      ..['max_ms'] = [
        existing['max_ms']! as num,
        group['max_ms']! as num,
      ].reduce((a, b) => a > b ? a : b)
      ..['last_at'] = [
        existing['last_at']! as int,
        group['last_at']! as int,
      ].reduce((a, b) => a > b ? a : b);
    into[key] = merged;
  }

  static List<Map<String, Object?>> _top(
    Iterable<Map<String, Object?>> groups,
    String kind,
    int limit,
  ) {
    final list = [
      for (final group in groups)
        {
          ...group,
          'avg_ms': (group['total_ms']! as num) / (group['count']! as int),
        }..remove('key'),
    ];
    int byCount(Map<String, Object?> a, Map<String, Object?> b) =>
        (b['count']! as int).compareTo(a['count']! as int);
    int byMax(Map<String, Object?> a, Map<String, Object?> b) =>
        (b['max_ms']! as num).compareTo(a['max_ms']! as num);
    list.sort(
      kind == 'exceptions'
          ? (a, b) {
              final c = byCount(a, b);
              return c != 0
                  ? c
                  : (b['last_at']! as int).compareTo(a['last_at']! as int);
            }
          : (a, b) {
              final c = byMax(a, b);
              return c != 0 ? c : byCount(a, b);
            },
    );
    return list.take(limit).toList();
  }
}
