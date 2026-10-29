import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;

/// One kind of request `test:stress` sends, and the statuses it expects.
final class StressScenario {
  const StressScenario({
    required this.name,
    required this.description,
    required this.path,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.expected = const {200},
    this.public = true,
  });

  final String name;
  final String description;
  final String method;
  final String path;
  final Map<String, String> headers;
  final String? body;

  /// Statuses that count as answered as intended (`{422, 429}` for a
  /// rate-limited login); anything else is an error.
  final Set<int> expected;

  /// Whether [path] may appear in a public export (not for routes given
  /// with `--path`, which may name internals).
  final bool public;
}

/// One round of one scenario.
final class StressRound {
  StressRound({
    required this.elapsed,
    required this.latenciesUs,
    required this.statuses,
  });

  final Duration elapsed;
  final List<int> latenciesUs;

  /// Status → count; 0 counts requests that got no response.
  final Map<int, int> statuses;

  int get requests => latenciesUs.length;
  double get rps => requests / (elapsed.inMicroseconds / 1e6);
}

/// The rounds of a scenario, summarised.
final class StressResult {
  StressResult(this.scenario, this.rounds);

  final StressScenario scenario;
  final List<StressRound> rounds;

  late final List<int> _sorted = [
    for (final round in rounds) ...round.latenciesUs,
  ]..sort();

  late final Map<int, int> statuses = () {
    final all = <int, int>{};
    for (final round in rounds) {
      round.statuses.forEach((k, v) => all[k] = (all[k] ?? 0) + v);
    }
    return all;
  }();

  int get requests => _sorted.length;

  double get rpsMean =>
      rounds.map((r) => r.rps).reduce((a, b) => a + b) / rounds.length;

  /// The sample standard deviation of the rounds' throughput (0 for one).
  double get rpsStdev {
    if (rounds.length < 2) {
      return 0;
    }
    final mean = rpsMean;
    final sum = rounds
        .map((r) => math.pow(r.rps - mean, 2))
        .reduce((a, b) => a + b);
    return math.sqrt(sum / (rounds.length - 1));
  }

  /// The [q] quantile of the latencies in milliseconds (nearest rank).
  double quantileMs(double q) {
    if (_sorted.isEmpty) {
      return 0;
    }
    final rank = (q * _sorted.length).ceil().clamp(1, _sorted.length);
    return _sorted[rank - 1] / 1000;
  }

  /// Responses with a 5xx status.
  int get serverErrors => statuses.entries
      .where((e) => e.key >= 500)
      .fold(0, (sum, e) => sum + e.value);

  /// Requests without a response (refused, reset, timed out).
  int get connectionErrors => statuses[0] ?? 0;

  /// Responses with a status the scenario does not expect, 5xx included.
  int get unexpected => statuses.entries
      .where((e) => e.key != 0 && !scenario.expected.contains(e.key))
      .fold(0, (sum, e) => sum + e.value);

  int get errors => unexpected + connectionErrors;

  Map<String, Object?> toJson({bool public = false}) => {
    'scenario': scenario.name,
    if (!public || scenario.public) ...{
      'method': scenario.method,
      'path': scenario.path,
    },
    // A route given with --path may name internals: not in a public report.
    'description': public && !scenario.public
        ? '${scenario.method} of a route given with --path'
        : scenario.description,
    'rounds': rounds.length,
    'requests': requests,
    'rps_mean': _round(rpsMean),
    'rps_stdev': _round(rpsStdev),
    if (!public) 'rps_rounds': [for (final r in rounds) _round(r.rps)],
    'latency_ms': {
      'p50': _round(quantileMs(.50)),
      'p90': _round(quantileMs(.90)),
      'p95': _round(quantileMs(.95)),
      'p99': _round(quantileMs(.99)),
      'max': _round(quantileMs(1)),
    },
    'statuses': public
        ? _classes(statuses)
        : {for (final e in statuses.entries) '${e.key}': e.value},
    'server_errors': serverErrors,
    'errors': errors,
  };

  static Map<String, int> _classes(Map<int, int> statuses) {
    final classes = <String, int>{};
    statuses.forEach((status, count) {
      final key = status == 0 ? 'no_response' : '${status ~/ 100}xx';
      classes[key] = (classes[key] ?? 0) + count;
    });
    return classes;
  }

  static double _round(double value) => (value * 100).roundToDouble() / 100;
}

/// Sends [requests] requests of [scenario] to [base] from [concurrency]
/// connections spread over [isolates] isolates.
Future<StressRound> runStressRound(
  Uri base,
  StressScenario scenario, {
  required int requests,
  required int concurrency,
  int isolates = 1,
}) async {
  final parts = math.max(1, math.min(isolates, concurrency));
  final url = base.resolve(scenario.path).toString();
  final method = scenario.method;
  final headers = scenario.headers;
  final body = scenario.body;
  final stopwatch = Stopwatch()..start();
  final results = await Future.wait([
    for (var i = 0; i < parts; i++)
      () {
        final share = requests ~/ parts + (i < requests % parts ? 1 : 0);
        final connections =
            concurrency ~/ parts + (i < concurrency % parts ? 1 : 0);
        return parts == 1
            ? _drive(url, method, headers, body, share, connections)
            : Isolate.run(
                () => _drive(url, method, headers, body, share, connections),
              );
      }(),
  ]);
  stopwatch.stop();
  final latencies = <int>[];
  final statuses = <int, int>{};
  for (final (part, counts) in results) {
    latencies.addAll(part);
    counts.forEach((k, v) => statuses[k] = (statuses[k] ?? 0) + v);
  }
  return StressRound(
    elapsed: stopwatch.elapsed,
    latenciesUs: latencies,
    statuses: statuses,
  );
}

Future<(List<int>, Map<int, int>)> _drive(
  String url,
  String method,
  Map<String, String> headers,
  String? body,
  int requests,
  int connections,
) async {
  final client = HttpClient()
    ..maxConnectionsPerHost = connections
    ..connectionTimeout = const Duration(seconds: 10);
  final uri = Uri.parse(url);
  final bytes = body == null ? null : utf8.encode(body);
  final latencies = <int>[];
  final statuses = <int, int>{};
  var sent = 0;
  Future<void> loop() async {
    while (sent < requests) {
      sent++;
      final watch = Stopwatch()..start();
      var status = 0;
      try {
        final request = await client.openUrl(method, uri);
        headers.forEach(request.headers.set);
        if (bytes != null) {
          request.contentLength = bytes.length;
          request.add(bytes);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        await response.drain<void>();
        status = response.statusCode;
      } on Object {
        status = 0;
      }
      latencies.add(watch.elapsedMicroseconds);
      statuses[status] = (statuses[status] ?? 0) + 1;
    }
  }

  await Future.wait([
    for (var i = 0; i < math.max(1, connections); i++) loop(),
  ]);
  client.close(force: true);
  return (latencies, statuses);
}

/// The scenarios `test:stress` can run against [base], found by probing
/// it: the health check, `/api/ping`, a 404, `/api/auth/me` with the token
/// of a synthetic user it registers, a rate-limited login, and [paths].
Future<(List<StressScenario>, List<String>)> discoverScenarios(
  Uri base, {
  List<String> paths = const [],
  DateTime? now,
}) async {
  const json = {
    'accept': 'application/json',
    'content-type': 'application/json',
  };
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final notes = <String>[];
  Future<(int, String)> send(
    String method,
    String path, {
    Map<String, String> headers = json,
    Object? body,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    headers.forEach(request.headers.set);
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  }

  try {
    final scenarios = <StressScenario>[];
    if ((await send('GET', '/up')).$1 == 200) {
      scenarios.add(
        const StressScenario(
          name: 'health',
          description: 'The health check: routing and the kernel.',
          path: '/up',
        ),
      );
    }
    if ((await send('GET', '/api/ping')).$1 == 200) {
      scenarios.add(
        const StressScenario(
          name: 'ping',
          description: 'A JSON route through the API middleware.',
          path: '/api/ping',
          headers: json,
        ),
      );
    }
    scenarios.add(
      const StressScenario(
        name: 'not_found',
        description: "An unknown route: Laravel's 404 body.",
        path: '/api/stress-test-unknown-route',
        headers: json,
        expected: {404},
      ),
    );
    final stamp = (now ?? DateTime.now()).microsecondsSinceEpoch;
    final (registered, answer) = await send(
      'POST',
      '/api/auth/register',
      body: {
        'name': 'Stress Test',
        'email': 'stress_$stamp@example.test',
        'password': 'Stress-test-$stamp',
        'password_confirmation': 'Stress-test-$stamp',
      },
    );
    if (registered == 201 || registered == 200) {
      final token = (jsonDecode(answer) as Map<String, Object?>)['token'];
      if (token is String) {
        scenarios.add(
          StressScenario(
            name: 'auth_me',
            description: 'A bearer token checked and its user loaded.',
            path: '/api/auth/me',
            headers: {...json, 'authorization': 'Bearer $token'},
          ),
        );
      }
    } else if (registered == 429) {
      notes.add('auth_me skipped: registration is rate limited, try later.');
    } else if (registered != 404 && registered != 405) {
      notes.add('auth_me skipped: registering answered $registered.');
    }
    final (login, _) = await send(
      'POST',
      '/api/auth/login',
      body: {'email': 'stress_$stamp@example.test', 'password': 'wrong'},
    );
    if (login != 404 && login != 405) {
      scenarios.add(
        StressScenario(
          name: 'rate_limit',
          description: 'Failed logins past the limit: 422, then 429.',
          method: 'POST',
          path: '/api/auth/login',
          headers: json,
          body: jsonEncode({
            'email': 'stress_limit_$stamp@example.test',
            'password': 'wrong',
          }),
          expected: const {422, 429},
        ),
      );
    }
    for (final (i, path) in paths.indexed) {
      scenarios.add(
        StressScenario(
          name: 'custom_${i + 1}',
          description: 'GET $path',
          path: path,
          headers: json,
          public: false,
        ),
      );
    }
    return (scenarios, notes);
  } finally {
    client.close(force: true);
  }
}

/// What may be published of a run (Blueprint #45, sanitization protocol):
/// built from an allowlist, so the target, tokens, synthetic users, custom
/// paths and host names never reach it. Statuses are given by class.
Map<String, Object?> publicStressReport(
  List<StressResult> results, {
  required Map<String, Object?> settings,
  DateTime? date,
}) => {
  'date': (date ?? DateTime.now().toUtc()).toIso8601String().substring(0, 10),
  'environment': {
    'os': Platform.operatingSystem,
    'cpus': Platform.numberOfProcessors,
    'dart': Platform.version.split(' ').first,
    'daravel': daravelVersion,
  },
  'settings': settings,
  'scenarios': [for (final r in results) r.toJson(public: true)],
};

/// `test:stress`: load against a running application, in rounds, with a
/// pass or fail for CI (Blueprint #45).
final class TestStressCommand extends Command<int> {
  TestStressCommand() {
    argParser
      ..addOption(
        'url',
        defaultsTo: 'http://127.0.0.1:8000',
        help: 'The running application.',
      )
      ..addOption(
        'scenario',
        help:
            'Comma separated: health, ping, not_found, auth_me, rate_limit, '
            'custom_N. All that the application has by default.',
      )
      ..addMultiOption(
        'path',
        help: 'Also a GET of this route, expecting 200 (repeatable).',
      )
      ..addOption('rounds', defaultsTo: '3', help: 'Rounds per scenario.')
      ..addOption('requests', defaultsTo: '1000', help: 'Requests per round.')
      ..addOption('concurrency', defaultsTo: '25', help: 'Open connections.')
      ..addOption(
        'isolates',
        defaultsTo:
            '${math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2))}',
        help: 'Client isolates the connections are spread over.',
      )
      ..addOption(
        'warmup',
        defaultsTo: '200',
        help: 'Requests sent before the rounds and not counted.',
      )
      ..addOption('cooldown', defaultsTo: '2', help: 'Seconds between rounds.')
      ..addOption('max-p95', help: 'Fail above this p95, in milliseconds.')
      ..addOption('min-rps', help: 'Fail below this mean throughput.')
      ..addOption('json', help: 'Write the full report (private) here.')
      ..addOption(
        'export-public',
        help:
            'Write a report safe to publish here: statistics only, no URL, '
            'tokens, users or custom paths.',
      );
  }

  @override
  String get name => 'test:stress';

  @override
  String get description =>
      'Load a running application in rounds and check its latency and errors.';

  @override
  Future<int> run() async {
    final r = argResults!;
    int number(String name, {int min = 0}) {
      final value = int.tryParse(r[name] as String);
      if (value == null || value < min) {
        usageException('--$name must be a number of at least $min.');
      }
      return value;
    }

    double? limit(String name) {
      final raw = r[name] as String?;
      if (raw == null) {
        return null;
      }
      final value = double.tryParse(raw.replaceAll(RegExp(r'ms$'), ''));
      if (value == null) {
        usageException('--$name must be a number.');
      }
      return value;
    }

    final base = Uri.parse(r['url'] as String);
    final rounds = number('rounds', min: 1);
    final requests = number('requests', min: 1);
    final concurrency = number('concurrency', min: 1);
    final isolates = number('isolates', min: 1);
    final warmup = number('warmup');
    final cooldown = Duration(seconds: number('cooldown'));
    final maxP95 = limit('max-p95');
    final minRps = limit('min-rps');

    final List<StressScenario> found;
    final List<String> notes;
    try {
      (found, notes) = await discoverScenarios(
        base,
        paths: r['path'] as List<String>,
      );
    } on Object catch (error) {
      stderr.writeln('Cannot reach $base: $error');
      return 1;
    }
    final wanted = (r['scenario'] as String?)
        ?.split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final scenarios = [
      for (final s in found)
        if (wanted == null || wanted.contains(s.name)) s,
    ];
    for (final missing
        in wanted?.difference({for (final s in found) s.name}) ??
            const <String>{}) {
      notes.add('$missing: not available on this application.');
    }
    notes.forEach(stdout.writeln);
    if (scenarios.isEmpty) {
      stderr.writeln('No scenario to run.');
      return 1;
    }

    stdout.writeln(
      'test:stress $base: ${scenarios.length} scenarios × $rounds rounds × '
      '$requests requests, $concurrency connections on $isolates isolates\n',
    );
    final results = <StressResult>[];
    for (final scenario in scenarios) {
      if (warmup > 0) {
        await runStressRound(
          base,
          scenario,
          requests: warmup,
          concurrency: concurrency,
          isolates: isolates,
        );
      }
      final done = <StressRound>[];
      for (var i = 0; i < rounds; i++) {
        if (i > 0 && cooldown > Duration.zero) {
          await Future<void>.delayed(cooldown);
        }
        done.add(
          await runStressRound(
            base,
            scenario,
            requests: requests,
            concurrency: concurrency,
            isolates: isolates,
          ),
        );
      }
      final result = StressResult(scenario, done);
      results.add(result);
      stdout.writeln(renderStressRow(result));
    }

    final failures = stressFailures(results, maxP95: maxP95, minRps: minRps);
    stdout.writeln();
    if (failures.isEmpty) {
      stdout.writeln('Passed.');
    } else {
      for (final failure in failures) {
        stdout.writeln('FAIL $failure');
      }
    }
    final settings = {
      'rounds': rounds,
      'requests_per_round': requests,
      'concurrency': concurrency,
      'client_isolates': isolates,
      'warmup': warmup,
    };
    final jsonPath = r['json'] as String?;
    if (jsonPath != null) {
      File(jsonPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'target': base.toString(),
            'settings': settings,
            'scenarios': [for (final result in results) result.toJson()],
            'failures': failures,
          }),
        );
      stdout.writeln('Report: $jsonPath');
    }
    final publicPath = r['export-public'] as String?;
    if (publicPath != null) {
      File(publicPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ')
              .convert(publicStressReport(results, settings: settings)),
        );
      stdout.writeln('Public report: $publicPath');
    }
    return failures.isEmpty ? 0 : 1;
  }
}

/// One line of the terminal table.
String renderStressRow(StressResult result) {
  String ms(double value) => value.toStringAsFixed(2).padLeft(8);
  final rps =
      '${result.rpsMean.toStringAsFixed(0)} ± '
      '${result.rpsStdev.toStringAsFixed(0)}';
  return '${result.scenario.name.padRight(12)}'
      '${'${result.rounds.length} × ${result.requests ~/ result.rounds.length}'.padLeft(12)}'
      '${rps.padLeft(16)} req/s'
      '  p50${ms(result.quantileMs(.5))}'
      '  p95${ms(result.quantileMs(.95))}'
      '  p99${ms(result.quantileMs(.99))} ms'
      '  errors ${result.errors}';
}

/// Why a run fails: any 5xx, request without a response or unexpected
/// status, and the thresholds. The rate-limited login is held to its
/// statuses only: its latency includes password hashing by design.
List<String> stressFailures(
  List<StressResult> results, {
  double? maxP95,
  double? minRps,
}) => [
  for (final result in results) ...[
    if (result.serverErrors > 0)
      '${result.scenario.name}: ${result.serverErrors} server errors (5xx)',
    if (result.connectionErrors > 0)
      '${result.scenario.name}: ${result.connectionErrors} requests without a response',
    if (result.unexpected - result.serverErrors > 0)
      '${result.scenario.name}: ${result.unexpected - result.serverErrors} '
          'unexpected statuses (expected ${result.scenario.expected.join('/')})',
    if (result.scenario.name != 'rate_limit') ...[
      if (maxP95 != null && result.quantileMs(.95) > maxP95)
        '${result.scenario.name}: p95 ${result.quantileMs(.95).toStringAsFixed(2)} ms > $maxP95 ms',
      if (minRps != null && result.rpsMean < minRps)
        '${result.scenario.name}: ${result.rpsMean.toStringAsFixed(0)} req/s < $minRps',
    ],
  ],
];
