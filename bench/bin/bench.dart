import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel_bench/load.dart';
import 'package:path/path.dart' as p;

/// Benchmark harness (BLUEPRINT_V2 §10.2):
///
/// ```bash
/// dart run bin/bench.dart                         # all scenarios, isolates 1 and 4
/// dart run bin/bench.dart --duration=5 --isolates=1,4,8 --out=results.json
/// dart run bin/bench.dart --compare=baseline.json # fail on > 10% regression
/// ```
///
/// Builds `bin/server.dart` (Daravel) and `bin/baseline.dart` (plain
/// `dart:io`) with `dart build cli`, seeds a SQLite database, then measures
/// startup, idle RSS and each scenario. Throughput is also reported relative
/// to the `dart:io` baseline measured in the same run, which is what
/// `--compare` gates on: absolute numbers depend on the machine, ratios much
/// less.
///
/// `--external=laravel-octane:8000` measures the same scenarios against a
/// server that is already running (the Laravel comparison in
/// `bench/laravel/`) and nothing else.
///
/// `--connections=16,64,256,1024` measures every scenario at each of those
/// connection counts (the saturation curve of `bench/public.sh`); each
/// result names its count.
///
/// `--serve --isolates=4 --port=18600` seeds and starts the Daravel server
/// and keeps it running until SIGINT or SIGTERM, for an external load
/// generator (`bench/public.sh` checks the harness against `oha` with it).
Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.external.isNotEmpty) {
    await _measureExternal(options);
    return;
  }
  final root = p.dirname(p.dirname(Platform.script.toFilePath()));
  final build = p.join(root, 'build');
  if (!options.skipBuild) {
    for (final target in ['server', 'baseline']) {
      await _run(Platform.resolvedExecutable, [
        'build',
        'cli',
        '-t',
        'bin/$target.dart',
        '-o',
        p.join(build, target),
      ], root);
    }
  }
  String exe(String target) => p.join(
    build,
    target,
    'bundle',
    'bin',
    Platform.isWindows ? '$target.exe' : target,
  );
  final database = options.database ?? p.join(build, 'bench.sqlite');
  final env = <String, String>{
    'APP_ENV': 'production',
    'APP_DEBUG': 'false',
    'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
    'APP_HOST': '127.0.0.1',
    'DB_DATABASE': database,
    'HASH_DRIVER': 'bcrypt',
    'BCRYPT_ROUNDS': '10',
    'LOG_LEVEL': 'error',
    'DB_POOL_SIZE': '4',
  };
  await _run(exe('server'), ['--seed'], root, environment: env);

  if (options.serve) {
    await _serve(exe('server'), env, options);
    return;
  }

  final results = <Map<String, Object?>>[];
  final startup = <Map<String, Object?>>[];
  final micro = jsonDecode(
    (await Process.run(exe('server'), ['--micro'], environment: env)).stdout
        as String,
  ) as Map<String, Object?>;
  stdout.writeln('zone microbenchmark: $micro');

  for (final isolates in options.isolates) {
    final port = 18500 + isolates;
    final serverEnv = {
      ...env,
      'APP_PORT': '$port',
      'APP_ISOLATES': '$isolates',
    };

    final baseline = await _Server.start(
      exe('baseline'),
      serverEnv,
      port,
      cpus: options.serverCpus,
    );
    // dart:io at every connection count, the reference of each point.
    final pings = <int, LoadResult>{};
    for (final connections in options.connections) {
      final ping = await _measure(
        options,
        port,
        const LoadSpec('GET', '/ping'),
        connections,
      );
      pings[connections] = ping;
      results.add({
        'scenario': '0-dartio-ping',
        'isolates': isolates,
        'connections': connections,
        ...ping.toJson(),
      });
      _print('0-dartio-ping', isolates, connections, ping);
    }
    await baseline.stop();

    final server = await _Server.start(
      exe('server'),
      serverEnv,
      port,
      cpus: options.serverCpus,
    );
    startup.add({
      'isolates': isolates,
      'startup_ms': server.startup.inMilliseconds,
      'rss_idle_kb': await _rssKb(server.process.pid),
    });
    for (final (name, spec) in _scenarios) {
      if (!options.scenarios.any(name.startsWith)) {
        continue;
      }
      for (final connections in options.connections) {
        final result = await _measure(options, port, spec, connections);
        final ping = pings[connections]!;
        results.add({
          'scenario': name,
          'isolates': isolates,
          'connections': connections,
          ...result.toJson(),
          'relative_to_dartio': double.parse(
            (result.rps / ping.rps).toStringAsFixed(4),
          ),
        });
        _print(name, isolates, connections, result, ping.rps);
      }
    }
    await server.stop();
  }

  final report = {
    'meta': {
      'date': DateTime.now().toUtc().toIso8601String(),
      'dart': Platform.version.split(' ').first,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'cpus': Platform.numberOfProcessors,
      'duration_s': options.duration.inSeconds,
      'connections': options.connections,
    },
    'startup': startup,
    'zone': micro,
    'results': results,
  };
  final targets = _targets([
    for (final r in results)
      if (r['connections'] == options.connections.first) r,
  ]);
  report['targets'] = targets;
  stdout.writeln('\nstartup: $startup\ntargets: $targets');
  if (options.out != null) {
    File(options.out!)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('Wrote ${options.out}.');
  }
  if (options.compare != null) {
    exitCode = _compare(results, options.compare!, options.threshold);
  }
}

/// Scenarios 1–6 of §10.2 (7 multipart and 8 SSE wait for Tier 2).
final List<(String, LoadSpec)> _scenarios = [
  ('1-ping', const LoadSpec('GET', '/ping')),
  ('2-show-json-query', const LoadSpec('GET', '/api/users/42')),
  (
    '3-store-validate-insert',
    LoadSpec(
      'POST',
      '/api/users',
      json: (i) => {'name': 'Bench $i', 'email': 'bench$i@example.com'},
    ),
  ),
  ('4-eager-loading', const LoadSpec('GET', '/api/posts')),
  ('5-throttled', const LoadSpec('GET', '/api/throttled')),
  ('6-login-hash', const LoadSpec('POST', '/api/login')),
];

Future<LoadResult> _measure(
  _Options options,
  int port,
  LoadSpec spec,
  int connections,
) => runLoad(
  port,
  spec,
  connections: connections,
  clientIsolates: min(options.clientIsolates, connections),
  duration: options.duration,
);

void _print(
  String name,
  int isolates,
  int connections,
  LoadResult r, [
  double? baseline,
]) {
  final relative = baseline == null
      ? ''
      : '  (${(r.rps / baseline * 100).toStringAsFixed(1)}% of dart:io)';
  stdout.writeln(
    '${name.padRight(26)} isolates=$isolates  c=$connections  '
    '${r.rps.toStringAsFixed(0).padLeft(7)} req/s  '
    'p50 ${r.percentile(50)} µs  p95 ${r.percentile(95)} µs  '
    'p99 ${r.percentile(99)} µs  errors ${r.errors}$relative',
  );
}

/// Internal relative targets of §10.2 (reported, not enforced).
Map<String, Object?> _targets(List<Map<String, Object?>> results) {
  Map<String, Object?>? find(String scenario, int isolates) => results
      .where((r) => r['scenario'] == scenario && r['isolates'] == isolates)
      .firstOrNull;
  final out = <String, Object?>{};
  final ping1 = find('1-ping', 1);
  if (ping1 != null) {
    final overhead = 1 - (ping1['relative_to_dartio']! as double);
    out['ping_overhead_vs_dartio'] =
        '${(overhead * 100).toStringAsFixed(1)}% (target ≤ 25%)';
  }
  final throttled = find('5-throttled', 1);
  final ping = find('1-ping', 1);
  if (throttled != null && ping != null) {
    // Service time per request on one isolate (1 / throughput): latency
    // percentiles under concurrent load are dominated by queueing.
    final added =
        1e6 / (throttled['rps']! as int) - 1e6 / (ping['rps']! as int);
    out['throttle_added_us_per_request'] =
        '${added.toStringAsFixed(1)} (target ≤ 100; ADR-024 aims < 30)';
  }
  final ping4 = find('1-ping', 4);
  if (ping1 != null && ping4 != null) {
    final scale = (ping4['rps']! as int) / max(1, ping1['rps']! as int);
    out['ping_scaling_4_vs_1'] =
        '${scale.toStringAsFixed(2)}x (target ≥ 3x on 4+ cores; '
        '${Platform.numberOfProcessors} cpus here)';
  }
  return out;
}

/// Fails (exit 1) when a scenario's throughput relative to `dart:io` fell
/// by more than [threshold] against [baselinePath].
int _compare(
  List<Map<String, Object?>> results,
  String baselinePath,
  double threshold,
) {
  final baseline =
      (jsonDecode(File(baselinePath).readAsStringSync())
              as Map<String, Object?>)['results']!
          as List<Object?>;
  var failed = 0;
  for (final current in results) {
    final relative = current['relative_to_dartio'] as double?;
    if (relative == null) {
      continue;
    }
    // Baselines written before `--connections` took a list ran at 64.
    final before = baseline.cast<Map<String, Object?>>().where(
      (b) =>
          b['scenario'] == current['scenario'] &&
          b['isolates'] == current['isolates'] &&
          (b['connections'] ?? 64) == current['connections'],
    );
    if (before.isEmpty) {
      continue;
    }
    final previous = (before.first['relative_to_dartio']! as num).toDouble();
    final change = (relative - previous) / previous;
    final label = '${current['scenario']} isolates=${current['isolates']}';
    if (change < -threshold) {
      failed++;
      stdout.writeln(
        'REGRESSION $label: ${(change * 100).toStringAsFixed(1)}% '
        '(relative ${previous.toStringAsFixed(3)} → ${relative.toStringAsFixed(3)})',
      );
    } else {
      stdout.writeln('ok $label: ${(change * 100).toStringAsFixed(1)}%');
    }
  }
  return failed == 0 ? 0 : 1;
}

final class _Server {
  _Server(this.process, this.startup);

  final Process process;
  final Duration startup;

  /// Starts [executable] and waits until `/up` answers (startup time).
  static Future<_Server> start(
    String executable,
    Map<String, String> env,
    int port, {
    String? cpus,
  }) async {
    final watch = Stopwatch()..start();
    // `--server-cpus` (Linux): the server gets its own cores, apart from
    // the load generator.
    final process = cpus == null
        ? await Process.start(executable, const [], environment: env)
        : await Process.start('taskset', [
            '-c',
            cpus,
            executable,
          ], environment: env);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/up'),
        )).close();
        await response.drain<void>();
        if (response.statusCode == 200) {
          break;
        }
      } on Object {
        if (DateTime.now().isAfter(deadline)) {
          process.kill();
          throw StateError('$executable did not become ready on port $port.');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    client.close(force: true);
    return _Server(process, watch.elapsed);
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
  }
}

Future<int?> _rssKb(int pid) async {
  if (Platform.isLinux) {
    final status = File('/proc/$pid/status').readAsLinesSync();
    final line = status.firstWhere(
      (l) => l.startsWith('VmRSS:'),
      orElse: () => '',
    );
    return int.tryParse(line.replaceAll(RegExp(r'[^0-9]'), ''));
  }
  final result = Platform.isWindows
      ? await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          '[int]((Get-Process -Id $pid).WorkingSet64 / 1KB)',
        ])
      : await Process.run('ps', ['-o', 'rss=', '-p', '$pid']);
  return int.tryParse((result.stdout as String).trim());
}

Future<void> _run(
  String executable,
  List<String> args,
  String workingDirectory, {
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(executable, args, 'exit code $code', code);
  }
}

final class _Options {
  _Options({
    required this.duration,
    required this.connections,
    required this.clientIsolates,
    required this.isolates,
    required this.scenarios,
    required this.skipBuild,
    required this.threshold,
    required this.external,
    required this.serve,
    required this.port,
    this.out,
    this.compare,
    this.database,
    this.serverCpus,
  });

  factory _Options.parse(List<String> args) {
    String? value(String name) {
      final prefix = '--$name=';
      return args
          .where((a) => a.startsWith(prefix))
          .map((a) => a.substring(prefix.length))
          .firstOrNull;
    }

    return _Options(
      duration: Duration(seconds: int.parse(value('duration') ?? '10')),
      connections: (value('connections') ?? '64')
          .split(',')
          .map(int.parse)
          .toList(),
      clientIsolates: int.parse(
        value('client-isolates') ??
            '${max(2, Platform.numberOfProcessors ~/ 2)}',
      ),
      isolates: (value('isolates') ?? '1,4').split(',').map(int.parse).toList(),
      scenarios: (value('scenarios') ?? '1,2,3,4,5,6').split(','),
      skipBuild: args.contains('--skip-build'),
      threshold: double.parse(value('threshold') ?? '0.10'),
      out: value('out'),
      compare: value('compare'),
      external: [
        for (final target in (value('external') ?? '').split(','))
          if (target.isNotEmpty)
            (
              target.substring(0, target.lastIndexOf(':')),
              int.parse(target.substring(target.lastIndexOf(':') + 1)),
            ),
      ],
      database: value('database'),
      serverCpus: value('server-cpus'),
      serve: args.contains('--serve'),
      port: int.parse(value('port') ?? '18600'),
    );
  }

  final Duration duration;

  /// Connection counts, each measured in turn (`--connections=16,64`).
  final List<int> connections;
  final int clientIsolates;
  final List<int> isolates;
  final List<String> scenarios;
  final bool skipBuild;
  final double threshold;
  final String? out;
  final String? compare;

  /// Servers already running, as (name, port): `--external=name:port,...`.
  final List<(String, int)> external;

  /// The SQLite database (`--database`, default `build/bench.sqlite`).
  final String? database;

  /// Cores for the servers (`--server-cpus=0-3`, Linux, via `taskset`).
  final String? serverCpus;

  /// `--serve`: run the server on [port] until stopped, measure nothing.
  final bool serve;
  final int port;
}

/// `--serve`: the Daravel server with `--isolates` workers on `--port`,
/// until SIGINT or SIGTERM (or until it exits on its own).
Future<void> _serve(
  String executable,
  Map<String, String> env,
  _Options options,
) async {
  final server = await _Server.start(
    executable,
    {
      ...env,
      'APP_PORT': '${options.port}',
      'APP_ISOLATES': '${options.isolates.first}',
    },
    options.port,
    cpus: options.serverCpus,
  );
  stdout.writeln(
    'Daravel serving on 127.0.0.1:${options.port} '
    '(${options.isolates.first} isolates); stop with SIGINT or SIGTERM.',
  );
  await Future.any<Object?>([
    ProcessSignal.sigint.watch().first,
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
    server.process.exitCode,
  ]);
  await server.stop();
}

/// `--external`: scenarios 1–6 against servers that are already running.
/// `--isolates` names their worker count in the report.
Future<void> _measureExternal(_Options options) async {
  final results = <Map<String, Object?>>[];
  final workers = options.isolates.first;
  for (final (name, port) in options.external) {
    await _waitUntilUp(port);
    for (final (scenario, spec) in _scenarios) {
      if (!options.scenarios.any(scenario.startsWith)) {
        continue;
      }
      for (final connections in options.connections) {
        final result = await _measure(options, port, spec, connections);
        results.add({
          'target': name,
          'scenario': scenario,
          'isolates': workers,
          'connections': connections,
          ...result.toJson(),
        });
        _print('$name $scenario', workers, connections, result);
      }
    }
  }
  if (options.out != null) {
    File(options.out!).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'meta': {
          'date': DateTime.now().toUtc().toIso8601String(),
          'os':
              '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
          'cpus': Platform.numberOfProcessors,
          'duration_s': options.duration.inSeconds,
          'connections': options.connections,
        },
        'results': results,
      }),
    );
    stdout.writeln('Wrote ${options.out}.');
  }
}

Future<void> _waitUntilUp(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  try {
    while (true) {
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/up'),
        )).close();
        await response.drain<void>();
        if (response.statusCode == 200) {
          return;
        }
      } on Object {
        // Not listening yet.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Nothing answered /up on port $port.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  } finally {
    client.close(force: true);
  }
}
