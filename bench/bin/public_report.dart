import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The report of a `bench/public.sh` run, from its results directory:
///
/// ```bash
/// dart run bin/public_report.dart results/2026-10-28-bench1          # Markdown
/// dart run bin/public_report.dart results/2026-10-28-bench1 --json   # summary
/// ```
///
/// The directory holds `environment.txt`, `runs/<n>/*.json` (repeated
/// `bench/laravel/compare.sh` runs), `curve/*.json` (one run at several
/// connection counts) and `oha/<server>_w<workers>_c<connections>_<scenario>.json`
/// (`oha --output-format json`). Throughput is the median of the runs with
/// their lowest and highest value, so one noisy run shows as spread instead
/// of moving the number.
void main(List<String> args) {
  final directory = args.firstWhere(
    (a) => !a.startsWith('--'),
    orElse: () => '.',
  );
  final runs = [
    for (final run in _directories(p.join(directory, 'runs'))) _load(run),
  ];
  final throughput = _summarise(runs);
  final pgRuns = [
    for (final run in _directories(p.join(directory, 'pgsql'))) _load(run),
  ];
  final pgsql = _summarise(pgRuns);
  final overloadRuns = [
    for (final run in _directories(p.join(directory, 'overload'))) _load(run),
  ];
  final overload = {
    for (final MapEntry(:key, :value) in _summarise(overloadRuns).entries)
      if (key.$2.startsWith('11-overload-')) key: value,
  };
  final curve = _summarise([
    if (Directory(p.join(directory, 'curve')).existsSync())
      _load(p.join(directory, 'curve')),
  ]);
  final oha = _oha(p.join(directory, 'oha'), throughput);

  if (args.contains('--json')) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'runs': runs.length,
        'throughput': [for (final s in throughput.values) s.toJson()],
        'pgsql_runs': pgRuns.length,
        'pgsql': [for (final s in pgsql.values) s.toJson()],
        'overload_runs': overloadRuns.length,
        'overload': [for (final s in overload.values) s.toJson()],
        'curve': [for (final s in curve.values) s.toJson()],
        'oha': oha,
      }),
    );
    return;
  }

  final environment = File(p.join(directory, 'environment.txt'));
  stdout.writeln('# Daravel and Laravel under load\n');
  if (environment.existsSync()) {
    stdout
      ..writeln('```text')
      ..write(environment.readAsStringSync())
      ..writeln('```');
  }
  _throughputTables(
    'Throughput (SQLite)',
    'Every server reads one SQLite file on the same disk.',
    throughput,
    runs.length,
  );
  _throughputTables(
    'Throughput (PostgreSQL)',
    'The scenarios that query, against one PostgreSQL server on the '
        'servers\' cores, as a database on the same machine would be. '
        'Daravel keeps a pool of 4 connections per isolate; Octane one '
        'connection per worker; classic connects for every request.',
    pgsql,
    pgRuns.length,
  );
  _overloadTables('SQLite', overload, overloadRuns.length);
  _overloadTables('PostgreSQL', {
    for (final MapEntry(:key, :value) in pgsql.entries)
      if (key.$2.startsWith('11-overload-')) key: value,
  }, pgRuns.length);
  _curveTables(curve);
  _ohaTable(oha);
}

const _targets = {
  'dart:io': 'dart:io',
  'daravel': 'Daravel',
  'laravel-octane': 'Laravel Octane',
  'laravel-classic': 'Laravel classic',
};

const _scenarios = {
  '1-ping': 'GET /ping',
  '2-show-json-query': 'JSON + one query',
  '3-store-validate-insert': 'validation + insert',
  '4-eager-loading': 'eager loading (20 posts)',
  '5-throttled': 'rate limited route',
  '6-login-hash': 'login (bcrypt)',
};

typedef _Key = (String target, String scenario, int workers, int connections);

/// One cell: the same measurement over every run.
final class _Summary {
  _Summary(this.key, List<Map<String, Object?>> samples)
    : rps = [for (final s in samples) s['rps']! as int]..sort(),
      p99 = [for (final s in samples) s['p99_us']! as int]..sort(),
      errors = samples.fold(0, (sum, s) => sum + (s['errors']! as int)),
      requests = samples.fold(0, (sum, s) => sum + (s['requests']! as int)),
      shed = samples.fold(0, (sum, s) => sum + (s['shed'] as int? ?? 0));

  final _Key key;
  final List<int> rps;
  final List<int> p99;
  final int errors;
  final int requests;

  /// `503`s refused by load shedding, over every run (scenario 11).
  final int shed;

  int get medianRps => _median(rps);
  int get medianP99 => _median(p99);

  Map<String, Object?> toJson() => {
    'target': key.$1,
    'scenario': key.$2,
    'workers': key.$3,
    'connections': key.$4,
    'runs': rps.length,
    'rps_median': medianRps,
    'rps_min': rps.first,
    'rps_max': rps.last,
    'p99_us_median': medianP99,
    'requests': requests,
    'errors': errors,
    if (shed > 0) 'shed': shed,
  };
}

int _median(List<int> sorted) {
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : ((sorted[middle - 1] + sorted[middle]) / 2).round();
}

List<String> _directories(String path) {
  final directory = Directory(path);
  if (!directory.existsSync()) {
    return const [];
  }
  return [
    for (final entry in directory.listSync())
      if (entry is Directory) entry.path,
  ]..sort();
}

/// The results of one run directory, keyed like [_Key]. The dart:io
/// reference counts as `1-ping` of the target `dart:io`.
Map<_Key, Map<String, Object?>> _load(String directory) {
  final results = <_Key, Map<String, Object?>>{};
  for (final file in Directory(directory).listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) {
      continue;
    }
    final report = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final result
        in (report['results']! as List<Object?>).cast<Map<String, Object?>>()) {
      var scenario = result['scenario']! as String;
      var target = result['target'] as String? ?? 'daravel';
      if (scenario == '0-dartio-ping') {
        (target, scenario) = ('dart:io', '1-ping');
      }
      final key = (
        target,
        scenario,
        result['isolates']! as int,
        result['connections'] as int? ?? 64,
      );
      results[key] = result;
    }
  }
  return results;
}

Map<_Key, _Summary> _summarise(List<Map<_Key, Map<String, Object?>>> runs) {
  final samples = <_Key, List<Map<String, Object?>>>{};
  for (final run in runs) {
    for (final MapEntry(:key, :value) in run.entries) {
      (samples[key] ??= []).add(value);
    }
  }
  return {
    for (final MapEntry(:key, :value) in samples.entries)
      key: _Summary(key, value),
  };
}

void _throughputTables(
  String title,
  String description,
  Map<_Key, _Summary> throughput,
  int runs,
) {
  if (throughput.isEmpty) {
    return;
  }
  final targets = ['daravel', 'laravel-octane', 'laravel-classic'];
  final workers = {for (final k in throughput.keys) k.$3}.toList()..sort();
  final connections = {for (final k in throughput.keys) k.$4}.toList()..sort();
  String cell(_Summary? s) {
    if (s == null) {
      return '–';
    }
    final spread = s.rps.length > 1
        ? ' (${_count(s.rps.first)}–${_count(s.rps.last)})'
        : '';
    final errors = s.errors > 0 ? ', ${_count(s.errors)} errors' : '';
    return '${_count(s.medianRps)} req/s$spread, p99 ${_ms(s.medianP99)}$errors';
  }

  stdout.writeln(
    '\n## $title\n\n$description Median of $runs run${runs == 1 ? '' : 's'}, '
    'lowest–highest in brackets; p99 is the median of the runs\' p99. '
    'Laravel classic boots the application for every request, as php-fpm '
    'does, and runs with the larger worker count only.',
  );
  for (final w in workers) {
    for (final c in connections) {
      final rows = <String>[];
      for (final MapEntry(key: id, value: label) in _scenarios.entries) {
        final row = [for (final t in targets) throughput[(t, id, w, c)]];
        if (row.every((s) => s == null)) {
          continue;
        }
        final ratio = row[0] == null || row[1] == null
            ? '–'
            : '${(row[0]!.medianRps / row[1]!.medianRps).toStringAsFixed(1)}×';
        rows.add('| $label | ${row.map(cell).join(' | ')} | $ratio |');
      }
      if (rows.isEmpty) {
        continue;
      }
      stdout
        ..writeln('\n### $w worker${w == 1 ? '' : 's'}, $c connections\n')
        ..writeln(
          '| Scenario | Daravel | Laravel Octane | Laravel classic | '
          'Daravel ÷ Octane |',
        )
        ..writeln('| :-- | --: | --: | --: | --: |');
      rows.forEach(stdout.writeln);
    }
  }
}

/// Scenario 11: one table per worker count, a row per server variant.
void _overloadTables(String database, Map<_Key, _Summary> overload, int runs) {
  if (overload.isEmpty) {
    return;
  }
  const variants = {
    '11-overload-unlimited': 'no limit',
    '11-overload-in-flight': '`HTTP_MAX_IN_FLIGHT`',
    '11-overload-queue-delay': '`HTTP_MAX_IN_FLIGHT` + `HTTP_MAX_QUEUE_DELAY`',
  };
  stdout.writeln(
    '\n## Overload (Daravel, $database)\n\nScenario 2\'s endpoint flooded '
    'with far more '
    'keep-alive connections than the workers can serve, without a limit and '
    'with [load shedding](https://github.com/daravel-dev/daravel/blob/main/'
    'docs/guide/deployment.md#load-shedding). '
    'Goodput counts successful responses only, p99 is of those; refused '
    'requests got `503` with `Retry-After` and are retried at once by the '
    'load generator, the worst case for the server. Median of $runs '
    'run${runs == 1 ? '' : 's'}.',
  );
  final workers = {for (final k in overload.keys) k.$3}.toList()..sort();
  for (final w in workers) {
    final rows = [
      for (final MapEntry(key: id, value: label) in variants.entries)
        for (final s in overload.values)
          if (s.key.$2 == id && s.key.$3 == w) (label, s),
    ];
    if (rows.isEmpty) {
      continue;
    }
    stdout
      ..writeln(
        '\n### $w worker${w == 1 ? '' : 's'}, '
        '${rows.first.$2.key.$4} connections\n',
      )
      ..writeln('| Limit | Goodput | p99 | Refused (503) | Errors |')
      ..writeln('| :-- | --: | --: | --: | --: |');
    for (final (label, s) in rows) {
      final attempts = s.requests + s.shed;
      final share = attempts == 0 ? 0 : s.shed * 100 / attempts;
      stdout.writeln(
        '| $label | ${_count(s.medianRps)} req/s | ${_ms(s.medianP99)} '
        '| ${share.toStringAsFixed(1)}% | ${_count(s.errors)} |',
      );
    }
  }
}

void _curveTables(Map<_Key, _Summary> curve) {
  if (curve.isEmpty) {
    return;
  }
  stdout.writeln(
    '\n## Saturation curve\n\nThe same scenario at a growing number of '
    'keep-alive connections. Throughput that stops growing while p99 '
    'climbs is the saturation point; errors are responses ≥ 400 and '
    'failed connections.',
  );
  final workers = {for (final k in curve.keys) k.$3}.toList()..sort();
  for (final w in workers) {
    for (final MapEntry(key: id, value: label) in _scenarios.entries) {
      final keys = [
        for (final k in curve.keys)
          if (k.$2 == id && k.$3 == w) k,
      ];
      if (keys.isEmpty) {
        continue;
      }
      final targets = [
        for (final t in _targets.keys)
          if (keys.any((k) => k.$1 == t)) t,
      ];
      final connections = {for (final k in keys) k.$4}.toList()..sort();
      stdout
        ..writeln('\n### $label, $w worker${w == 1 ? '' : 's'}\n')
        ..writeln(
          '| Connections | ${[for (final t in targets) _targets[t]].join(' | ')} |',
        )
        ..writeln('| --: | ${[for (final _ in targets) '--:'].join(' | ')} |');
      for (final c in connections) {
        final cells = [
          for (final t in targets)
            switch (curve[(t, id, w, c)]) {
              null => '–',
              final s =>
                '${_count(s.medianRps)} req/s, p99 ${_ms(s.medianP99)}'
                    '${s.errors > 0 ? ', ${_count(s.errors)} errors' : ''}',
            },
        ];
        stdout.writeln('| $c | ${cells.join(' | ')} |');
      }
    }
  }
}

/// The `oha` measurements next to the harness's median of the same server,
/// scenario, workers and connections.
List<Map<String, Object?>> _oha(
  String directory,
  Map<_Key, _Summary> throughput,
) {
  if (!Directory(directory).existsSync()) {
    return const [];
  }
  final name = RegExp(r'^(.+)_w(\d+)_c(\d+)_(.+)\.json$');
  final rows = <Map<String, Object?>>[];
  final files = Directory(directory).listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final match = name.firstMatch(p.basename(file.path));
    if (match == null) {
      continue;
    }
    final key = (
      match[1]!,
      match[4]!,
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
    final report = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final metrics = report['metrics']! as Map<String, Object?>;
    final latency = metrics['latency_ms']! as Map<String, Object?>;
    final codes =
        (report['statusCodeDistribution'] as Map<String, Object?>? ?? const {})
            .map((code, count) => MapEntry(code, count! as int));
    // Requests cut off by the deadline are not the server's errors.
    final errors =
        (report['errorDistribution'] as Map<String, Object?>? ?? const {})
            .entries
            .where((e) => e.key != 'aborted due to deadline')
            .fold(0, (sum, e) => sum + (e.value! as int));
    final harness = throughput[key];
    final ohaRps = (metrics['requests_per_sec']! as num).round();
    rows.add({
      'target': key.$1,
      'scenario': key.$2,
      'workers': key.$3,
      'connections': key.$4,
      'oha_rps': ohaRps,
      'oha_p99_us': ((latency['p99']! as num) * 1000).round(),
      'oha_status_codes': codes,
      'oha_errors': errors,
      'harness_rps_median': harness?.medianRps,
      'harness_p99_us_median': harness?.medianP99,
      'oha_vs_harness': harness == null
          ? null
          : double.parse((ohaRps / harness.medianRps).toStringAsFixed(3)),
    });
  }
  return rows;
}

void _ohaTable(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) {
    return;
  }
  stdout
    ..writeln(
      '\n## Cross-check with oha\n\nThe same servers measured by '
      '[oha](https://github.com/hatoo/oha), a load generator written in Rust, '
      'next to this harness\'s median. A ratio near 1.0 means the numbers '
      'above are not an artefact of the Dart load generator.\n',
    )
    ..writeln(
      '| Scenario | Server | Harness | oha | oha ÷ harness | '
      'p99 harness | p99 oha | Not 2xx |',
    )
    ..writeln('| :-- | :-- | --: | --: | --: | --: | --: | --: |');
  for (final r in rows) {
    final codes = r['oha_status_codes']! as Map<String, int>;
    final notOk =
        codes.entries
            .where((e) => !e.key.startsWith('2'))
            .fold(0, (sum, e) => sum + e.value) +
        (r['oha_errors']! as int);
    final harness = r['harness_rps_median'] as int?;
    final harnessP99 = r['harness_p99_us_median'] as int?;
    stdout.writeln(
      '| ${_scenarios[r['scenario']] ?? r['scenario']} '
      '| ${_targets[r['target']] ?? r['target']}, ${r['workers']} workers, '
      '${r['connections']} connections '
      '| ${harness == null ? '–' : '${_count(harness)} req/s'} '
      '| ${_count(r['oha_rps']! as int)} req/s '
      '| ${r['oha_vs_harness'] ?? '–'} '
      '| ${harnessP99 == null ? '–' : _ms(harnessP99)} '
      '| ${_ms(r['oha_p99_us']! as int)} '
      '| ${_count(notOk)} |',
    );
  }
}

/// 12160 → `12 160`, as the guide writes numbers.
String _count(int n) {
  final digits = '${n.abs()}';
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      out.write(' ');
    }
    out.write(digits[i]);
  }
  return '$out';
}

String _ms(int us) => us < 1000
    ? '$us µs'
    : '${(us / 1000).toStringAsFixed(us < 10000 ? 1 : 0)} ms';
