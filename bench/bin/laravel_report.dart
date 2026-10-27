import 'dart:convert';
import 'dart:io';

/// Prints the Daravel vs Laravel table (Markdown) from the JSON files that
/// `bench/laravel/compare.sh` writes into [directory]:
///
/// ```bash
/// dart run bin/laravel_report.dart ~/daravel-bench/data
/// ```
///
/// One table per worker count, and per connection count when the run
/// measured several (`CONNECTIONS=16,64,256`).
void main(List<String> args) {
  final directory = Directory(args.isEmpty ? '.' : args.first);
  // (target, scenario, workers, connections) → result
  final results = <(String, String, int, int), Map<String, Object?>>{};
  for (final file in directory.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) {
      continue;
    }
    final report = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final result
        in (report['results']! as List<Object?>).cast<Map<String, Object?>>()) {
      final scenario = result['scenario']! as String;
      final target =
          result['target'] as String? ??
          (scenario.startsWith('0-') ? 'dart:io' : 'daravel');
      // Runs from before `--connections` took a list used 64.
      final connections = result['connections'] as int? ?? 64;
      results[(target, scenario, result['isolates']! as int, connections)] =
          result;
    }
  }
  final targets = ['daravel', 'laravel-octane', 'laravel-classic'];
  final scenarios = {
    '1-ping': 'GET /ping',
    '2-show-json-query': 'JSON + one query',
    '3-store-validate-insert': 'validation + insert',
    '4-eager-loading': 'eager loading (20 posts)',
    '5-throttled': 'rate limited route',
    '6-login-hash': 'login (bcrypt)',
  };
  final workers = {for (final key in results.keys) key.$3}.toList()..sort();
  final connections = {for (final key in results.keys) key.$4}.toList()..sort();

  String cell(Map<String, Object?>? r) => r == null
      ? '–'
      : '${r['rps']} req/s, p99 ${_ms(r['p99_us']! as int)}'
            '${(r['errors']! as int) > 0 ? ', ${r['errors']} errors' : ''}';

  for (final w in workers) {
    for (final c in connections) {
      final heading = connections.length == 1
          ? '$w worker${w == 1 ? '' : 's'}'
          : '$w worker${w == 1 ? '' : 's'}, $c connections';
      final rows = <String>[];
      for (final MapEntry(key: id, value: label) in scenarios.entries) {
        final row = [for (final t in targets) results[(t, id, w, c)]];
        if (row.every((r) => r == null)) {
          continue;
        }
        final daravel = row[0];
        final octane = row[1];
        final ratio = daravel == null || octane == null
            ? '–'
            : '${((daravel['rps']! as int) / (octane['rps']! as int)).toStringAsFixed(1)}×';
        rows.add('| $label | ${row.map(cell).join(' | ')} | $ratio |');
      }
      if (rows.isEmpty) {
        continue;
      }
      stdout
        ..writeln('\n### $heading\n')
        ..writeln(
          '| Scenario | Daravel | Laravel Octane | Laravel classic | '
          'Daravel ÷ Octane |',
        )
        ..writeln('| :-- | --: | --: | --: | --: |');
      rows.forEach(stdout.writeln);
    }
  }
}

String _ms(int us) => us < 1000
    ? '$us µs'
    : '${(us / 1000).toStringAsFixed(us < 10000 ? 1 : 0)} ms';
