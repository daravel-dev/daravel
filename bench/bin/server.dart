import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_bench/bench_app.dart';

/// Benchmark server (built AOT by `bin/bench.dart`).
///
/// * no arguments: serve [createBenchApp] (`APP_ISOLATES` workers);
/// * `--seed`: create and seed the database, then exit;
/// * `--micro`: print the Zone/facade microbenchmark (scenario 9) as JSON.
Future<void> main(List<String> args) async {
  if (args.contains('--seed')) {
    final app = createBenchApp();
    await app.boot();
    await seedBenchDatabase(app);
    await app.shutdown();
    return;
  }
  if (args.contains('--micro')) {
    stdout.writeln(jsonEncode(await zoneMicrobenchmark()));
    return;
  }
  exitCode = await Application.serveWith(createBenchApp);
}

/// Cost of a request scope (`Container.runScoped`) and of a facade lookup
/// inside it, against a bare `runZoned`, in nanoseconds per operation.
Future<Map<String, Object?>> zoneMicrobenchmark() async {
  final app = createBenchApp();
  await app.boot();
  const rounds = 200000;
  Future<double> measure(Future<void> Function() body) async {
    for (var i = 0; i < rounds ~/ 10; i++) {
      await body(); // Warm-up.
    }
    final watch = Stopwatch()..start();
    for (var i = 0; i < rounds; i++) {
      await body();
    }
    return watch.elapsedMicroseconds * 1000 / rounds;
  }

  final container = Container.current;
  final bare = await measure(() async => runZoned(() => 1));
  final scope = await measure(() => container.runScoped('request', (_) => 1));
  final facade = await measure(
    () => container.runScoped('request', (_) => App.make<HashManager>()),
  );
  await app.shutdown();
  return {
    'bare_zone_ns': bare.round(),
    'scope_ns': scope.round(),
    'scope_plus_facade_ns': facade.round(),
    'zone_overhead_ns': (scope - bare).round(),
  };
}
