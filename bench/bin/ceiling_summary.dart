// One line per coordinator_ceiling.dart result (Blueprint #141, K0): the
// ceiling of each operation at 1/4/8/16 clients in thousands per second,
// the saturation p99s and the leases' over_limit.
//
//   dart run bin/ceiling_summary.dart results/2026-11-10-k0/k0_followup/ceiling-*.json
import 'dart:convert';
import 'dart:io';

void main(List<String> files) {
  for (final f in files) {
    final j = jsonDecode(File(f).readAsStringSync()) as Map;
    final c = j['ceiling'] as Map;
    final line = StringBuffer(f.split(RegExp(r'[\/]')).last);
    for (final op in ['rate', 'cache', 'publish', 'noop', 'send']) {
      final m = c[op] as Map?;
      if (m == null) continue;
      line.write(
        '  $op ${[
          for (final n in ['1', '4', '8', '16']) '${((m[n] as Map)['ops_per_s'] as num) ~/ 1000}k',
        ].join('/')}',
      );
    }
    final s = j['saturation'] as Map;
    line.write(
      '  sat alone p99 ${(s['rate_alone'] as Map)['p99_us']}us flood p99 ${(s['rate_under_flood'] as Map)['p99_us']}us errors ${(s['rate_under_flood'] as Map)['errors']} publish/s ${s['publish_per_s']}',
    );
    final lease = j['lease'] as Map;
    line.write(
      '  over_limit ${lease.values.map((v) => (v as Map)['over_limit']).toSet()}',
    );
    print(line);
  }
}
