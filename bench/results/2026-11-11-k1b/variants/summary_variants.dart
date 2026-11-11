// Summarises a variants folder (variants.sh): publish x 1/8/16 and
// saturation per variant. Fails when an expected key is missing.
import 'dart:convert';
import 'dart:io';

Object? at(String file, Object? v, List<String> path) {
  for (final k in path) {
    if (v is! Map || !v.containsKey(k)) {
      stderr.writeln('$file: missing ${path.join('.')}');
      exit(2);
    }
    v = v[k];
  }
  return v;
}

num median(List<num> xs) => ([...xs]..sort())[xs.length ~/ 2];

void main(List<String> args) {
  final runs = <String, List<(String, Object?)>>{};
  for (final f in Directory(args.single).listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json')) continue;
    final key = name.substring(0, name.lastIndexOf('_'));
    (runs[key] ??= []).add((name, jsonDecode(f.readAsStringSync())));
  }
  List<num> vals(String key, List<String> path) => [
    for (final (file, json) in runs[key] ?? const <(String, Object?)>[])
      at(file, json, path)! as num,
  ];
  const variants = ['main', 'k1b', 'a', 'b'];
  stdout.writeln('## publish ceiling, ops/s: median (min-max) [diff vs main]');
  for (final c in ['1', '8', '16']) {
    final base = median(
      vals('main_ceiling-publish', ['ceiling', 'publish', c, 'ops_per_s']),
    );
    final cells = <String>[];
    for (final v in variants) {
      final xs = vals('${v}_ceiling-publish', [
        'ceiling',
        'publish',
        c,
        'ops_per_s',
      ]);
      final m = median(xs);
      final s = [...xs]..sort();
      final d = v == 'main'
          ? ''
          : ' [${((m / base - 1) * 100).toStringAsFixed(1)} %]';
      cells.add(
        '$v ${(m / 1000).toStringAsFixed(1)}k (${(s.first / 1000).toStringAsFixed(0)}-${(s.last / 1000).toStringAsFixed(0)})$d',
      );
    }
    stdout.writeln('x$c: ${cells.join(' | ')}');
  }
  stdout.writeln('\n## saturation');
  for (final v in variants) {
    List<num> s(List<String> p) =>
        vals('${v}_saturation', ['saturation', ...p]);
    stdout.writeln(
      '$v: p99 rate under flood ${s(['rate_under_flood', 'p99_us'])} us; '
      'alone ${s(['rate_alone', 'p99_us'])}; publish/s ${s(['publish_per_s'])}; '
      'refused ${s(['publish_refused'])}; errors ${s(['rate_under_flood', 'errors'])}',
    );
  }
}
