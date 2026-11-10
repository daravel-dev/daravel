// Coordinator messages per request (Blueprint #141, K0 §3.11 item 2), per
// coordinator service, read from the server's own /metrics
// (`coordinator_call_duration_seconds_count{service}`, every worker
// isolate added up) before and after a number of requests.
//
//   dart run bin/bench.dart --scenarios=1 --duration=1   # builds build/server
//   dart run bin/coordinator_census.dart --isolates=4 --requests=20000 [--json]
//
// Scenarios: 2 (one query, no coordinator work), 5 (rate limiter),
// 14 (token + rate limiter + `process` cache), 14-jwt (the same with a JWT,
// whose denylist is a coordinator cache) and broadcast (one publish).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    for (final a in args) {
      if (a.startsWith('--$name=')) {
        return a.substring(name.length + 3);
      }
    }
    return fallback;
  }

  final root = Directory.current.path;
  final exe = option(
    'server',
    p.join(
      root,
      'build',
      'server',
      'bundle',
      'bin',
      Platform.isWindows ? 'server.exe' : 'server',
    ),
  );
  final isolates = option('isolates', '4');
  final requests = int.parse(option('requests', '20000'));
  final connections = int.parse(option('connections', '32'));
  final port = int.parse(option('port', '18690'));
  final json = args.contains('--json');
  final database = p.join(root, 'build', 'census.sqlite');
  final env = <String, String>{
    'APP_ENV': 'production',
    'APP_DEBUG': 'false',
    'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
    'APP_HOST': '127.0.0.1',
    'APP_PORT': '$port',
    'APP_ISOLATES': isolates,
    'DB_DATABASE': database,
    'HASH_DRIVER': 'bcrypt',
    'BCRYPT_ROUNDS': '10',
    'LOG_LEVEL': 'error',
    'METRICS_ENABLED': 'true',
    'BENCH_CACHE_STORE': 'process',
  };
  final seed = await Process.run(exe, ['--seed'], environment: env);
  if (seed.exitCode != 0) {
    stderr.writeln('seed failed: ${seed.stderr}');
    exit(1);
  }
  final server = await Process.start(exe, const [], environment: env);
  unawaited(server.stderr.drain<void>());
  unawaited(server.stdout.drain<void>());
  final client = HttpClient()..maxConnectionsPerHost = connections;
  final base = Uri.parse('http://127.0.0.1:$port');
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      try {
        final r = await (await client.getUrl(base.resolve('/up'))).close();
        await r.drain<void>();
        if (r.statusCode == 200) {
          break;
        }
      } on IOException {
        // Not up yet.
      }
      if (DateTime.now().isAfter(deadline)) {
        stderr.writeln('server did not start');
        exit(1);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final jwtResponse = await (await client.postUrl(
      base.resolve('/api/jwt-token'),
    )).close();
    final jwt =
        (jsonDecode(await utf8.decodeStream(jwtResponse))
                as Map<String, Object?>)['token']!
            as String;

    final scenarios = <String, (String, String, Map<String, String>)>{
      '2-show-json-query': ('GET', '/api/users/42', {}),
      '5-throttled': ('GET', '/api/throttled', {}),
      '14-token-throttle-cache': (
        'GET',
        '/api/session',
        {'Authorization': 'Bearer 1|bench-session-token-0123456789abcdefghijk'},
      ),
      '14-jwt-throttle-cache': (
        'GET',
        '/api/session-jwt',
        {'Authorization': 'Bearer $jwt'},
      ),
      'broadcast-publish': ('POST', '/api/broadcast', {}),
    };

    Future<Map<String, double>> calls() async {
      final r = await (await client.getUrl(base.resolve('/metrics'))).close();
      final text = await utf8.decodeStream(r);
      final out = <String, double>{};
      final line = RegExp(
        r'^coordinator_call_duration_seconds_count\{([^}]*)\}\s+(\S+)$',
      );
      for (final raw in LineSplitter.split(text)) {
        final m = line.firstMatch(raw.trim());
        if (m == null) {
          continue;
        }
        final service =
            RegExp(r'service="([^"]*)"').firstMatch(m[1]!)?[1] ?? '';
        out[service] = (out[service] ?? 0) + (double.tryParse(m[2]!) ?? 0);
      }
      return out;
    }

    Future<int> drive(
      (String, String, Map<String, String>) spec,
      int count,
    ) async {
      final (method, path, headers) = spec;
      var sent = 0;
      var failed = 0;
      Future<void> lane() async {
        while (sent < count) {
          sent++;
          final request = await client.openUrl(method, base.resolve(path));
          headers.forEach(request.headers.set);
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode >= 400) {
            failed++;
          }
        }
      }

      await Future.wait([for (var i = 0; i < connections; i++) lane()]);
      return failed;
    }

    final out = <String, Object?>{
      'isolates': int.parse(isolates),
      'requests': requests,
      'connections': connections,
    };
    for (final MapEntry(key: name, value: spec) in scenarios.entries) {
      await drive(spec, 500); // Warm-up, leases taken.
      // Workers publish their metrics every second: let them settle.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final before = await calls();
      final failed = await drive(spec, requests);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final after = await calls();
      final per = <String, double>{
        for (final service in {...before.keys, ...after.keys})
          if ((after[service] ?? 0) - (before[service] ?? 0) > 0)
            service: double.parse(
              (((after[service] ?? 0) - (before[service] ?? 0)) / requests)
                  .toStringAsFixed(4),
            ),
      };
      final total = per.entries
          .where((e) => e.key != 'metrics')
          .fold<double>(0, (a, e) => a + e.value);
      out[name] = {
        'messages_per_request': double.parse(total.toStringAsFixed(4)),
        'by_service': per,
        'failed': failed,
      };
      if (!json) {
        stdout.writeln('$name: ${jsonEncode(out[name])}');
      }
    }
    if (json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
    }
  } finally {
    client.close(force: true);
    server.kill();
    await server.exitCode;
  }
}
