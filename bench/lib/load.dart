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
