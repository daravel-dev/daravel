import 'dart:io';

import 'package:yaml/yaml.dart';

/// The rules of the sample applications in `apps/` (Blueprint #136,
/// ADR-035 proposed), checked by `tool/sample_apps_check.dart`.
///
/// Packages every application uses, which need no sample of their own.
const Set<String> everyApp = {
  'daravel',
  'daravel_test',
  'daravel_lints',
  // A dev tool enabled in analysis_options.yaml (plugins:), like the
  // lints themselves: it needs no sample of its own.
  'daravel_lints_plugin',
  'dartisan_cli',
};

/// The files each application has (structure of `apps/daravel_starter`).
const List<String> requiredFiles = [
  'bin/dartisan.dart',
  'test',
  'README.md',
  'README.id.md',
  '.env.example',
];

/// The applications Blueprint #136 plans but that do not exist yet, by
/// package. A package listed here may have no application for now; each
/// SA pull request that adds an application removes it from this map.
const Map<String, List<String>> planned = {
  'daravel_activitylog': ['event_hub_demo'],
  'daravel_excel': ['excel_demo', 'storefront_demo', 'event_hub_demo'],
  'daravel_google': ['event_hub_demo'],
  'daravel_horizon': ['ops_console'],
  'daravel_livekit': ['event_hub_demo'],
  'daravel_log_viewer': ['log_viewer_demo', 'ops_console'],
  'daravel_medialibrary': ['files_demo', 'storefront_demo', 'event_hub_demo'],
  'daravel_mysql': ['database_matrix_demo'],
  'daravel_payments': ['payments_demo', 'storefront_demo', 'event_hub_demo'],
  'daravel_permission': ['event_hub_demo'],
  'daravel_postgres': ['database_matrix_demo'],
  'daravel_pulse': ['pulse_demo', 'ops_console'],
  'daravel_redis': ['redis_demo', 'ops_console', 'api_gateway_demo'],
  'daravel_reverb': ['ops_console'],
  'daravel_reverb_client': ['reverb_client_demo'],
  'daravel_s3': ['s3_demo', 'storefront_demo'],
  'daravel_scout': ['scout_demo', 'api_gateway_demo'],
  'daravel_session': ['session_demo', 'storefront_demo'],
  'daravel_sqlite': ['database_matrix_demo'],
  'daravel_teobiefy': ['teobiefy_demo', 'api_gateway_demo'],
  'daravel_teorion': ['event_hub_demo'],
};

/// The workspace: package names (under `packages/`) and, by application
/// name (under `apps/`), the workspace packages it depends on.
final class Workspace {
  /// [packages] and [apps] as read from disk, or given by a test.
  const Workspace(this.packages, this.apps, {this.missingFiles = const {}});

  /// The workspace under [root].
  factory Workspace.read(String root) {
    List<Directory> dirs(String path) {
      final dir = Directory('$root/$path');
      if (!dir.existsSync()) {
        return const [];
      }
      return [
        for (final entry in dir.listSync())
          if (entry is Directory &&
              File('${entry.path}/pubspec.yaml').existsSync())
            entry,
      ]..sort((a, b) => a.path.compareTo(b.path));
    }

    String name(Directory dir) =>
        dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final packages = [for (final dir in dirs('packages')) name(dir)];
    final apps = <String, Set<String>>{};
    final missing = <String, List<String>>{};
    for (final dir in dirs('apps')) {
      final pubspec = loadYaml(
        File('${dir.path}/pubspec.yaml').readAsStringSync(),
      ) as YamlMap;
      apps[name(dir)] = {
        for (final section in ['dependencies', 'dev_dependencies'])
          if (pubspec[section] case final YamlMap deps)
            for (final key in deps.keys)
              if (packages.contains('$key')) '$key',
      };
      missing[name(dir)] = [
        for (final file in requiredFiles)
          if (FileSystemEntity.typeSync('${dir.path}/$file') ==
              FileSystemEntityType.notFound)
            file,
      ];
    }
    return Workspace(packages, apps, missingFiles: missing);
  }

  /// The package names.
  final List<String> packages;

  /// The workspace packages each application depends on.
  final Map<String, Set<String>> apps;

  /// The [requiredFiles] each application lacks.
  final Map<String, List<String>> missingFiles;

  /// The packages that need a sample application (not [everyApp]).
  List<String> get sampled => [
    for (final package in packages)
      if (!everyApp.contains(package)) package,
  ];

  /// The applications using [package].
  List<String> appsOf(String package) => [
    for (final MapEntry(key: app, value: deps) in apps.entries)
      if (deps.contains(package)) app,
  ];
}

/// What breaks the rules in [workspace] with [planned] apps.
List<String> sampleAppProblems(
  Workspace workspace, {
  Map<String, List<String>> planned = planned,
}) => [
  for (final package in workspace.sampled)
    if (workspace.appsOf(package).isEmpty &&
        (planned[package] ?? const []).isEmpty)
      '$package is used by no application in apps/ and none is planned '
          'for it (tool/sample_apps.dart).',
  for (final MapEntry(key: package, value: apps) in planned.entries)
    for (final app in apps)
      if (workspace.apps.containsKey(app))
        'apps/$app exists: remove it from the planned apps of $package '
            '(tool/sample_apps.dart)${workspace.apps[app]!.contains(package) ? '' : ', or add $package to its dependencies'}.',
  for (final MapEntry(key: app, value: files) in workspace.missingFiles.entries)
    for (final file in files) 'apps/$app has no $file.',
];

/// `apps/README.md`: the package × application matrix of [workspace].
String renderAppsReadme(
  Workspace workspace, {
  Map<String, List<String>> planned = planned,
}) {
  final apps = workspace.apps.keys.toList();
  final buffer = StringBuffer()
    ..writeln('# Sample applications')
    ..writeln()
    ..writeln(
      '<!-- Generated by `dart run tool/sample_apps_check.dart --write`; '
      'do not edit. -->',
    )
    ..writeln()
    ..writeln(
      'Each application in this directory runs and is tested in CI, with the '
      'structure of `daravel_starter`. Every package has, or will have, an '
      'application that uses it on its own and one that combines it with '
      'others (Blueprint #136). `daravel`, `daravel_test`, `daravel_lints` '
      'and `dartisan_cli` are in every application.',
    )
    ..writeln()
    ..writeln(
      '| Package | ${[for (final app in apps) '`$app`'].join(' | ')} | Planned |',
    )
    ..writeln('| :-- |${' :-: |' * apps.length} :-- |');
  for (final package in workspace.sampled) {
    final cells = [
      for (final app in apps) workspace.apps[app]!.contains(package) ? '✓' : '',
    ];
    final later = [
      for (final app in planned[package] ?? const <String>[]) '`$app`',
    ];
    buffer.writeln(
      '| `$package` | ${cells.join(' | ')} | ${later.join(', ')} |',
    );
  }
  buffer
    ..writeln()
    ..writeln(
      '| Application | Workspace packages besides those in every application |',
    )
    ..writeln('| :-- | :-- |');
  for (final app in apps) {
    final deps = [
      for (final dep in workspace.apps[app]!.toList()..sort())
        if (!everyApp.contains(dep)) '`$dep`',
    ];
    buffer.writeln(
      '| [`$app`]($app/README.md) | ${deps.isEmpty ? 'core only' : deps.join(', ')} |',
    );
  }
  return buffer.toString();
}
