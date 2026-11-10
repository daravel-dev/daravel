// Median and range of runs of compare.sh (Blueprint #141, K0): the run
// directories of one variant as arguments (each with daravel.json and
// laravel-*.json), one line per scenario (1, 5 and 14), worker count and
// server.
//
//   dart run bin/runs_summary.dart results/2026-11-10-k0/k0_pgsql/pgsql-redis-{1,2,3}
import 'dart:convert';
import 'dart:io';

void main(List<String> dirs) {
  // key: scenario|isolates|target -> list of (rps, p99 ms, errors)
  final rows = <String, List<(num, num, num)>>{};
  for (final dir in dirs) {
    for (final f in Directory(dir).listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map;
      final name = f.uri.pathSegments.last.replaceAll('.json', '');
      final target = name == 'daravel'
          ? 'daravel'
          : name.replaceAll(RegExp(r'-\d+$'), '');
      for (final r in (j["results"] as List).cast<Map<String, Object?>>()) {
        final s = r['scenario'] as String;
        if (!RegExp(r'^(1|5|14)-').hasMatch(s)) continue;
        final key = '$s|${r['isolates']}|$target';
        rows.putIfAbsent(key, () => []).add((
          r['rps'] as num,
          (r['p99_us'] as num) / 1000,
          r['errors'] as num,
        ));
      }
    }
  }
  num med(List<num> v) {
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }

  final keys = rows.keys.toList()..sort();
  for (final k in keys) {
    final v = rows[k]!;
    final rps = v.map((e) => e.$1).toList();
    final p99 = v.map((e) => e.$2).toList();
    final errs = v.fold<num>(0, (a, e) => a + e.$3);
    final lo = rps.reduce((a, b) => a < b ? a : b),
        hi = rps.reduce((a, b) => a > b ? a : b);
    final spread = (hi - lo) / med(rps) * 100;
    print(
      '$k n=${v.length} rps ${med(rps)} [$lo-$hi] spread ${spread.toStringAsFixed(1)}% p99 ${med(p99).toStringAsFixed(1)} ms errors $errs',
    );
  }
}
