import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

/// One method and URI of a route.
typedef RouteKey = ({String method, String uri});

/// Laravel's routes against Daravel's, for a migration route by route
/// (the strangler fig pattern, Blueprint #29): which Laravel routes
/// Daravel answers already, which still go to Laravel through
/// `withUpstream`, and which exist in Daravel only.
final class RouteDiff {
  RouteDiff._(this.migrated, this.legacy, this.daravelOnly);

  /// Compares [laravel] with [daravel]. Methods are compared one by one
  /// (`GET|HEAD` is `GET`), URIs without their leading slash and parameter
  /// names (`users/{user}` matches `/users/{id}`, `{id?}` and `{id}` too).
  factory RouteDiff.compute(
    Iterable<RouteKey> laravel,
    Iterable<RouteKey> daravel,
  ) {
    final ours = {for (final route in daravel) _normal(route)};
    final theirs = {for (final route in laravel) _normal(route)};
    final migrated = <RouteKey>[];
    final legacy = <RouteKey>[];
    for (final route in _sorted(laravel)) {
      (ours.contains(_normal(route)) ? migrated : legacy).add(route);
    }
    return RouteDiff._(migrated, legacy, [
      for (final route in _sorted(daravel))
        if (!theirs.contains(_normal(route))) route,
    ]);
  }

  /// Laravel routes Daravel answers.
  final List<RouteKey> migrated;

  /// Laravel routes Daravel does not answer: `withUpstream` forwards them.
  final List<RouteKey> legacy;

  /// Daravel routes Laravel does not have.
  final List<RouteKey> daravelOnly;

  int get total => migrated.length + legacy.length;

  /// Progress per module, most routes left first: the first segment after
  /// `api` and a version (`api/v1/ikk/rekap` is `ikk`).
  List<({String prefix, int migrated, int total})> byPrefix() {
    final done = <String, int>{};
    final all = <String, int>{};
    for (final route in migrated) {
      final prefix = _prefix(route.uri);
      done[prefix] = (done[prefix] ?? 0) + 1;
      all[prefix] = (all[prefix] ?? 0) + 1;
    }
    for (final route in legacy) {
      final prefix = _prefix(route.uri);
      all[prefix] = (all[prefix] ?? 0) + 1;
    }
    final rows = [
      for (final MapEntry(:key, :value) in all.entries)
        (prefix: key, migrated: done[key] ?? 0, total: value),
    ];
    return rows..sort((a, b) {
      final left = (b.total - b.migrated).compareTo(a.total - a.migrated);
      return left != 0 ? left : a.prefix.compareTo(b.prefix);
    });
  }

  static String _prefix(String uri) {
    final segments = _strip(uri).split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.first == 'api') {
      segments.removeAt(0);
    }
    if (segments.isNotEmpty && RegExp(r'^v\d+$').hasMatch(segments.first)) {
      segments.removeAt(0);
    }
    return segments.isEmpty || segments.first.startsWith('{')
        ? '/'
        : segments.first;
  }

  /// The table of [byPrefix].
  String renderByPrefix() {
    final rows = byPrefix();
    final width = rows.fold(
      6,
      (w, r) => r.prefix.length > w ? r.prefix.length : w,
    );
    return [
      '${'Prefix'.padRight(width)}  Migrated  Left',
      for (final r in rows)
        '${r.prefix.padRight(width)}  '
            '${'${r.migrated}/${r.total}'.padLeft(8)}  '
            '${'${r.total - r.migrated}'.padLeft(4)}',
    ].join('\n');
  }

  /// The share of Laravel's routes Daravel answers, 0 to 100.
  double get percent => total == 0 ? 100 : migrated.length * 100 / total;

  /// One key per method of `php artisan route:list --json` output, without
  /// `HEAD` (it follows `GET`).
  static List<RouteKey> parseLaravel(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! List) {
      throw const FormatException(
        'Expected the array of `php artisan route:list --json`.',
      );
    }
    return [
      for (final route in decoded.cast<Map<String, Object?>>())
        for (final method in '${route['method']}'.split('|'))
          if (method.isNotEmpty && method != 'HEAD')
            (method: method, uri: '${route['uri']}'),
    ];
  }

  /// The routes of a Daravel router, one key per method, without `HEAD`.
  static List<RouteKey> fromRouter(Router router) => [
    for (final route in router.routes)
      for (final method in route.methods)
        if (method != 'HEAD') (method: method, uri: route.path),
  ];

  static final RegExp _parameter = RegExp(r'\{[^}/]+\}');

  static RouteKey _normal(RouteKey route) {
    var uri = route.uri.trim();
    while (uri.startsWith('/')) {
      uri = uri.substring(1);
    }
    while (uri.endsWith('/')) {
      uri = uri.substring(0, uri.length - 1);
    }
    return (
      method: route.method.toUpperCase(),
      uri: uri.replaceAll(_parameter, '{}'),
    );
  }

  static List<RouteKey> _sorted(Iterable<RouteKey> routes) {
    final seen = <RouteKey>{};
    return [
      for (final route in routes)
        if (seen.add(_normal(route))) route,
    ]..sort((a, b) {
      final byUri = _normal(a).uri.compareTo(_normal(b).uri);
      return byUri != 0 ? byUri : a.method.compareTo(b.method);
    });
  }

  Map<String, Object?> toJson() {
    List<Map<String, String>> list(List<RouteKey> routes) => [
      for (final r in routes) {'method': r.method, 'uri': r.uri},
    ];
    return {
      'total': total,
      'migrated': list(migrated),
      'legacy': list(legacy),
      'daravel_only': list(daravelOnly),
      'percent': (percent * 10).roundToDouble() / 10,
      'by_prefix': [
        for (final r in byPrefix())
          {'prefix': r.prefix, 'migrated': r.migrated, 'total': r.total},
      ],
    };
  }

  /// The terminal report.
  String render() {
    final filled = (percent / 5).round();
    String line(RouteKey r, String where) {
      final label = '  ${r.method.padRight(7)}/${_strip(r.uri)} ';
      return '${label.padRight(60, '.')} $where';
    }

    return [
      'Laravel routes          : $total',
      'Answered by Daravel     : ${migrated.length}',
      'Still Laravel (upstream): ${legacy.length}',
      'Migrated                : ${percent.toStringAsFixed(1)}% '
          '[${'█' * filled}${'░' * (20 - filled)}]',
      if (migrated.isNotEmpty) ...[
        '',
        'Answered by Daravel:',
        for (final r in migrated) line(r, 'DARAVEL'),
      ],
      if (legacy.isNotEmpty) ...[
        '',
        'Still in Laravel:',
        for (final r in legacy) line(r, 'LARAVEL'),
      ],
      if (daravelOnly.isNotEmpty) ...[
        '',
        'Only in Daravel:',
        for (final r in daravelOnly) line(r, 'NEW'),
      ],
    ].join('\n');
  }

  static String _strip(String uri) =>
      uri.startsWith('/') ? uri.substring(1) : uri;
}

/// `route:diff (--laravel=<dir> | --laravel-json=<file>) [--json]`:
/// Laravel's routes against this application's ([RouteDiff]).
final class RouteDiffCommand extends DaravelCommand {
  RouteDiffCommand(super.createApp) {
    argParser
      ..addOption(
        'laravel',
        help: 'The Laravel application: runs `php artisan route:list --json`.',
      )
      ..addOption(
        'laravel-json',
        help: 'The saved output of `php artisan route:list --json`.',
      )
      ..addFlag('json', negatable: false, help: 'Print the diff as JSON.')
      ..addFlag(
        'by-prefix',
        negatable: false,
        help: 'Print progress per module instead of every route.',
      );
  }

  @override
  String get name => 'route:diff';

  @override
  String get description =>
      'Compare the Laravel application\'s routes with this one\'s.';

  @override
  Future<int> run() async {
    final r = argResults!;
    final directory = r['laravel'] as String?;
    final file = r['laravel-json'] as String?;
    if ((directory == null) == (file == null)) {
      usageException('Give --laravel=<dir> or --laravel-json=<file>.');
    }
    String json;
    if (file != null) {
      json = File(file).readAsStringSync();
    } else {
      final ProcessResult result;
      try {
        result = await Process.run('php', [
          'artisan',
          'route:list',
          '--json',
        ], workingDirectory: directory);
      } on ProcessException {
        stderr.writeln(
          'php was not found. Save `php artisan route:list --json` to a file '
          'and pass --laravel-json.',
        );
        return 1;
      }
      if (result.exitCode != 0) {
        stderr
          ..writeln('php artisan route:list --json failed:')
          ..write(result.stderr);
        return 1;
      }
      json = result.stdout as String;
    }
    final List<RouteKey> laravel;
    try {
      laravel = RouteDiff.parseLaravel(json);
    } on FormatException catch (error) {
      stderr.writeln('Not route:list JSON: ${error.message}');
      return 1;
    }
    return withApp((app) {
      final diff = RouteDiff.compute(laravel, RouteDiff.fromRouter(app.router));
      stdout.writeln(
        r['json'] == true
            ? const JsonEncoder.withIndent('  ').convert(diff.toJson())
            : r['by-prefix'] == true
            ? diff.renderByPrefix()
            : diff.render(),
      );
      return 0;
    });
  }
}
