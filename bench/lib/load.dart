import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

/// One benchmark request shape.
final class LoadSpec {
  const LoadSpec(this.method, this.path, {this.json});

  final String method;
  final String path;
  final Object? Function(int sequence)? json;
}

/// Result of a load run: throughput and latency percentiles of the
/// successful requests; [shed] counts the `503`s a server refused with
/// load shedding (`HTTP_MAX_IN_FLIGHT`), apart from other errors.
final class LoadResult {
  LoadResult(
    this.requests,
    this.errors,
    this.elapsed,
    List<int> latencies, {
    this.shed = 0,
  }) : _sorted = (List<int>.of(latencies)..sort());

  final int requests;
  final int errors;
  final int shed;
  final Duration elapsed;
  final List<int> _sorted;

  double get rps => requests / (elapsed.inMicroseconds / 1e6);

  /// Share of attempts the server refused with `503`.
  double get shedShare => requests + shed == 0 ? 0 : shed / (requests + shed);

  /// Latency percentile in microseconds.
  int percentile(double p) => _sorted.isEmpty
      ? 0
      : _sorted[min(_sorted.length - 1, (p / 100 * _sorted.length).floor())];

  Map<String, Object?> toJson() => {
    'requests': requests,
    'errors': errors,
    'rps': rps.round(),
    'p50_us': percentile(50),
    'p95_us': percentile(95),
    'p99_us': percentile(99),
    if (shed > 0) 'shed': shed,
  };
}

/// Drives [spec] against `http://127.0.0.1:[port]` with [connections]
/// keep-alive connections spread over [clientIsolates] isolates, so the
/// client is not the bottleneck (the generator runs in this process; use
/// `--oha` for an external generator).
Future<LoadResult> runLoad(
  int port,
  LoadSpec spec, {
  int connections = 64,
  int clientIsolates = 4,
  Duration duration = const Duration(seconds: 10),
  Duration warmup = const Duration(seconds: 2),
}) async {
  final perIsolate = max(1, connections ~/ clientIsolates);
  Future<_WorkerResult> spawn(Duration d) =>
      Isolate.run(() => _worker(port, spec, perIsolate, d));
  await Future.wait([for (var i = 0; i < clientIsolates; i++) spawn(warmup)]);
  final watch = Stopwatch()..start();
  final parts = await Future.wait([
    for (var i = 0; i < clientIsolates; i++) spawn(duration),
  ]);
  final elapsed = watch.elapsed;
  return LoadResult(
    parts.fold(0, (sum, p) => sum + p.ok),
    parts.fold(0, (sum, p) => sum + p.errors),
    elapsed,
    [for (final p in parts) ...p.latencies],
    shed: parts.fold(0, (sum, p) => sum + p.shed),
  );
}

typedef _WorkerResult = ({int ok, int errors, int shed, List<int> latencies});

Future<_WorkerResult> _worker(
  int port,
  LoadSpec spec,
  int connections,
  Duration duration,
) async {
  final client = HttpClient()..maxConnectionsPerHost = connections;
  final uri = Uri.parse('http://127.0.0.1:$port${spec.path}');
  final end = DateTime.now().add(duration);
  final latencies = <int>[];
  var ok = 0;
  var errors = 0;
  var shed = 0;
  var sequence = Isolate.current.hashCode;
  await Future.wait([
    for (var c = 0; c < connections; c++)
      () async {
        while (DateTime.now().isBefore(end)) {
          final watch = Stopwatch()..start();
          try {
            final request = await client.openUrl(spec.method, uri);
            final body = spec.json?.call(sequence++);
            if (body != null) {
              final bytes = utf8.encode(jsonEncode(body));
              request.headers
                ..contentType = ContentType.json
                ..contentLength = bytes.length;
              request.add(bytes);
            }
            final response = await request.close();
            await response.drain<void>();
            if (response.statusCode < 400) {
              ok++;
              latencies.add(watch.elapsedMicroseconds);
            } else if (response.statusCode == HttpStatus.serviceUnavailable) {
              // Load shedding closes the connection; the next attempt opens
              // one again, at once: the harness is a client that ignores
              // `Retry-After`, which is the worst case for the server.
              shed++;
            } else {
              errors++;
            }
          } on Object {
            errors++;
          }
        }
      }(),
  ]);
  client.close(force: true);
  return (ok: ok, errors: errors, shed: shed, latencies: latencies);
}

/// Open loop: [rate] requests per second arrive whatever the server does,
/// as from many independent users, spread over [clientIsolates] isolates
/// with up to [connections] keep-alive connections in all. A refused
/// request is not retried, unlike [runLoad], whose clients send the next
/// request as soon as one is answered, so the number waiting never falls.
///
/// Latency runs from when a request was *due*, not from when it was sent:
/// time spent waiting for a free connection or behind a slow server counts
/// (no coordinated omission). The connections open during [warmup], a few
/// at a time, so none is refused for arriving in a burst. After [duration]
/// the requests still outstanding get
/// [grace] to finish; the rest count as errors. Throughput is completions
/// of the requests due within [duration], per second of it (goodput).
Future<LoadResult> runOpenLoop(
  int port,
  LoadSpec spec, {
  required double rate,
  int connections = 512,
  int clientIsolates = 4,
  Duration duration = const Duration(seconds: 10),
  Duration warmup = const Duration(seconds: 2),
  Duration grace = const Duration(seconds: 2),
}) async {
  final perIsolate = max(1, connections ~/ clientIsolates);
  final perRate = rate / clientIsolates;
  final parts = await Future.wait([
    for (var i = 0; i < clientIsolates; i++)
      Isolate.run(
        () => _openWorker(
          port,
          spec,
          perIsolate,
          perRate,
          warmup,
          duration,
          grace,
        ),
      ),
  ]);
  return LoadResult(
    parts.fold(0, (sum, p) => sum + p.ok),
    parts.fold(0, (sum, p) => sum + p.errors),
    duration,
    [for (final p in parts) ...p.latencies],
    shed: parts.fold(0, (sum, p) => sum + p.shed),
  );
}

Future<_WorkerResult> _openWorker(
  int port,
  LoadSpec spec,
  int connections,
  double rate,
  Duration warmup,
  Duration duration,
  Duration grace,
) async {
  final client = HttpClient()..maxConnectionsPerHost = connections;
  final uri = Uri.parse('http://127.0.0.1:$port${spec.path}');
  final latencies = <int>[];
  var ok = 0;
  var errors = 0;
  var shed = 0;
  var outstanding = 0;
  var closed = false;
  var sequence = Isolate.current.hashCode;
  final clock = Stopwatch()..start();

  Future<void> send(int dueUs, {required bool counted}) async {
    if (counted) {
      outstanding++;
    }
    int? status;
    try {
      final request = await client.openUrl(spec.method, uri);
      final body = spec.json?.call(sequence++);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers
          ..contentType = ContentType.json
          ..contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      await response.drain<void>();
      status = response.statusCode;
    } on Object {
      status = null;
    }
    if (!counted || closed) {
      return;
    }
    outstanding--;
    if (status == null || (status >= 400 && status != 503)) {
      errors++;
    } else if (status == HttpStatus.serviceUnavailable) {
      shed++;
    } else {
      ok++;
      latencies.add(clock.elapsedMicroseconds - dueUs);
    }
  }

  /// Sends [perSecond] requests a second for [length] from now, each at its
  /// due time, without waiting for the answers.
  Future<List<Future<void>>> drive(
    double perSecond,
    Duration length, {
    required bool counted,
  }) async {
    final startUs = clock.elapsedMicroseconds;
    final interval = 1e6 / perSecond;
    final total = (length.inMicroseconds / interval).floor();
    final pending = <Future<void>>[];
    for (var i = 0; i < total; i++) {
      final due = startUs + (i * interval).round();
      final wait = due - clock.elapsedMicroseconds;
      if (wait > 0) {
        await Future<void>.delayed(Duration(microseconds: wait));
      } else if (i % 64 == 0) {
        // Behind schedule: still let answers in now and then.
        await Future<void>.delayed(Duration.zero);
      }
      pending.add(send(due, counted: counted));
    }
    return pending;
  }

  // Warm-up: open the connections a few at a time over its first half (a
  // burst of new connections overflows the kernel's SYN backlog, and the
  // refused ones would count against the server), each kept busy until the
  // warm-up ends, so the measured window starts with a full pool.
  final warmEnd = clock.elapsedMicroseconds + warmup.inMicroseconds;
  final step = warmup.inMicroseconds ~/ (2 * connections);
  await Future.wait([
    for (var c = 0; c < connections; c++)
      () async {
        await Future<void>.delayed(Duration(microseconds: c * step));
        while (clock.elapsedMicroseconds < warmEnd) {
          await send(clock.elapsedMicroseconds, counted: false);
        }
      }(),
  ]);
  final pending = await drive(rate, duration, counted: true);
  await Future.wait(pending).timeout(grace, onTimeout: () => const []);
  closed = true;
  errors += outstanding;
  client.close(force: true);
  return (ok: ok, errors: errors, shed: shed, latencies: latencies);
}
