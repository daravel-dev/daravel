// Summarises a K1b re-measurement folder (remeasure.sh): files named
// <variant>_<part>_<round>.json, part = ceiling-<op> | saturation |
// overflow | starved | lease. Fails when an expected key is missing.
import 'dart:convert';
import 'dart:io';

Never missing(String file, String path) {
  stderr.writeln('$file: missing $path');
  exit(2);
}

Object? at(String file, Map<String, Object?> m, List<String> path) {
  Object? v = m;
  for (final k in path) {
    if (v is! Map || !v.containsKey(k)) missing(file, path.join('.'));
    v = v[k];
  }
  return v;
}

double median(List<num> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2].toDouble();
}

String range(List<num> xs) {
  final s = [...xs]..sort();
  return '${s.first}-${s.last}';
}

void main(List<String> args) {
  final files = <String, Map<String, List<(String, Map<String, Object?>)>>>{};
  for (final f in Directory(args.single).listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json')) continue;
    final parts = name.substring(0, name.length - 5).split('_');
    if (parts.length != 3) continue;
    final text = f.readAsStringSync().trim();
    if (text.isEmpty) missing(name, 'content');
    ((files[parts[0]] ??= {})[parts[1]] ??= []).add((
      name,
      jsonDecode(text) as Map<String, Object?>,
    ));
  }
  final variants = files.keys.toList()..sort();
  final base = variants.contains('main') ? 'main' : null;

  List<num> values(String v, String part, List<String> path) => [
    for (final (file, json)
        in files[v]?[part] ?? const <(String, Map<String, Object?>)>[])
      at(file, json, path)! as num,
  ];

  stdout.writeln('## Healthy ceiling, ops/s: median (min-max) [diff vs main]');
  for (final op in ['rate', 'cache', 'noop', 'publish']) {
    for (final c in ['1', '8', '16']) {
      final cells = <String>[];
      final mainMedian = base == null
          ? null
          : median(
              values(base, 'ceiling-$op', ['ceiling', op, c, 'ops_per_s']),
            );
      for (final v in variants) {
        final xs = values(v, 'ceiling-$op', ['ceiling', op, c, 'ops_per_s']);
        if (xs.isEmpty) continue;
        final m = median(xs);
        final diff = mainMedian == null || v == base
            ? ''
            : ' [${((m / mainMedian - 1) * 100).toStringAsFixed(1)} %]';
        cells.add(
          '$v ${(m / 1000).toStringAsFixed(1)}k (${range([for (final x in xs) (x / 1000).round()])}k)$diff',
        );
      }
      stdout.writeln('$op x$c: ${cells.join(' | ')}');
    }
  }

  for (final part in ['saturation', 'overflow']) {
    stdout.writeln('\n## $part');
    for (final v in variants) {
      if (files[v]![part] == null) continue;
      List<num> s(List<String> p) => values(v, part, [
        part == 'overflow' ? 'saturation' : 'saturation',
        ...p,
      ]);
      stdout.writeln(
        '$v: p99 rate under flood ${median(s(['rate_under_flood', 'p99_us']))} us '
        '(${range(s(['rate_under_flood', 'p99_us']))}); alone p99 '
        '${median(s(['rate_alone', 'p99_us']))} us; publish/s '
        '${median(s(['publish_per_s']))} (${range(s(['publish_per_s']))}); '
        'refused ${s(['publish_refused']).join('/')}; errors '
        '${s(['rate_under_flood', 'errors']).join('/')}',
      );
    }
  }

  stdout.writeln('\n## starved (16 CPU burners, no flood)');
  for (final v in variants) {
    for (final (file, json)
        in files[v]!['starved'] ?? const <(String, Map<String, Object?>)>[]) {
      stdout.writeln(
        '$v $file: states ${at(file, json, ['starved', 'states_seen'])}, '
        'shed ${at(file, json, ['starved', 'shed'])}, publish errors '
        '${at(file, json, ['starved', 'publish_errors'])}, rate errors '
        '${at(file, json, ['starved', 'rate_errors'])}',
      );
    }
  }

  stdout.writeln('\n## leases');
  for (final v in variants) {
    for (final (file, json)
        in files[v]!['lease'] ?? const <(String, Map<String, Object?>)>[]) {
      final lease = jsonEncode(at(file, json, ['lease']));
      final over = RegExp(r'"over_limit":(\d+)').allMatches(lease).toList();
      if (over.isEmpty) missing(file, 'lease.*.over_limit');
      stdout.writeln(
        '$v $file: max over_limit ${over.map((m) => int.parse(m[1]!)).reduce((a, b) => a > b ? a : b)}',
      );
    }
  }
}
