// Summarises a K1b bench folder: medians of three runs per variant.
import 'dart:convert';
import 'dart:io';

double median(List<num> xs) {
  final s = [...xs]..sort();
  return s.isEmpty ? double.nan : s[s.length ~/ 2].toDouble();
}

void main(List<String> args) {
  final dir = Directory(args.single);
  final runs = <String, List<Map<String, Object?>>>{};
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json')) continue;
    final variant = name.substring(0, name.lastIndexOf('_'));
    final text = f.readAsStringSync();
    if (text.trim().isEmpty) continue;
    (runs[variant] ??= []).add(jsonDecode(text) as Map<String, Object?>);
  }
  final variants = runs.keys.toList()..sort();
  Object? at(Map<String, Object?> m, List<String> path) {
    Object? v = m;
    for (final k in path) {
      if (v is! Map) return null;
      v = v[k];
    }
    return v;
  }

  List<num> all(String v, List<String> path) => [
    for (final r in runs[v]!)
      if (at(r, path) case final num n) n,
  ];

  stdout.writeln('variant\truns');
  for (final v in variants) {
    stdout.writeln('$v\t${runs[v]!.length}');
  }
  stdout.writeln('\nCeiling ops/s (median), senders 1/8/16');
  for (final op in ['rate', 'cache', 'publish', 'noop']) {
    for (final v in variants) {
      final cells = [
        for (final c in ['1', '8', '16'])
          (median(all(v, ['ceiling', op, c, 'ops_per_s'])) / 1000)
              .toStringAsFixed(1),
      ];
      stdout.writeln('$op\t$v\t${cells.join(' / ')}k');
    }
  }
  stdout.writeln('\nSaturation (median; and each run)');
  for (final v in variants) {
    String m(List<String> p) => median(all(v, ['saturation', ...p])).toString();
    String each(List<String> p) => all(v, ['saturation', ...p]).join(', ');
    stdout.writeln(
      '$v\tp99 rate under flood us ${m(['rate_under_flood', 'p99_us'])} '
      '[${each(['rate_under_flood', 'p99_us'])}]\t'
      'alone p99 ${m(['rate_alone', 'p99_us'])} [${each(['rate_alone', 'p99_us'])}]\t'
      'publish/s ${m(['publish_per_s'])} [${each(['publish_per_s'])}]\t'
      'port msgs/1000 pub ${m(['port_messages_per_1000_publishes'])}\t'
      'refused ${each(['publish_refused'])}\t'
      'errors ${each(['rate_under_flood', 'errors'])}',
    );
  }
  stdout.writeln('\nLeases over limit');
  for (final v in variants) {
    final lease = runs[v]!.map((r) => jsonEncode(at(r, ['leases']))).toSet();
    final over = RegExp(r'"over_limit":(\d+)')
        .allMatches(lease.join())
        .map((m) => int.parse(m[1]!))
        .fold<int>(0, (a, b) => a > b ? a : b);
    stdout.writeln('$v\tmax over_limit $over');
  }
}
