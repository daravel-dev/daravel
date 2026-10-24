import 'dart:io';

import 'package:yaml/yaml.dart';

import 'site.dart';

/// Documentation site generator (BLUEPRINT_V2 §14.4, §11.3):
///
/// ```bash
/// dart run tool/docs/generate.dart                 # refresh docs/guide, build build/site
/// dart run tool/docs/generate.dart --check         # CI: fail when docs/guide is stale
/// dart run tool/docs/generate.dart --version=main --keep   # add a version to build/site
/// ```
///
/// 1. Renders `docs/guide/parity.md` from `parity.yaml` (side-by-side
///    Laravel ⇄ Daravel tables).
/// 2. Replaces every `<!-- include: path#region -->` … `<!-- /include -->`
///    block with that region of a compiled test file, so guide snippets are
///    the code the test suite runs.
/// 3. Builds the site into `build/site`: the landing pages, and the guide
///    of this checkout as `docs/<version>/` (sidebar from
///    `docs/guide/navigation.yaml`, versions from `docs/versions.yaml`).
///    `--keep` adds to an existing build, so the docs workflow can build
///    every version from its own branch into one site.
void main(List<String> args) {
  final check = args.contains('--check');
  String? option(String name) {
    for (final arg in args) {
      if (arg.startsWith('--$name=')) {
        return arg.substring(name.length + 3);
      }
    }
    return null;
  }

  if (args.contains('--list-versions')) {
    // "<id> <branch>" per line, for the docs workflow.
    final versions =
        loadYaml(File('docs/versions.yaml').readAsStringSync()) as YamlMap;
    for (final v in versions['versions'] as YamlList) {
      stdout.writeln('${(v as YamlMap)['id']} ${v['branch']}');
    }
    return;
  }

  final guide = Directory('docs/guide');
  final changed = <String>[];

  void write(File file, String content) {
    final current = file.existsSync() ? file.readAsStringSync() : null;
    if (current == content) {
      return;
    }
    changed.add(file.path);
    if (!check) {
      file.writeAsStringSync(content);
    }
  }

  write(File('docs/guide/parity.md'), renderParity(File('parity.yaml')));
  for (final file in _markdownFiles(guide)) {
    write(file, expandIncludes(file.readAsStringSync()));
  }
  final localNav = readNavigation(File('docs/guide/navigation.yaml'));
  final problems = checkNavigation(guide, localNav);
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    exitCode = 1;
    return;
  }

  // `--guide=<dir>`: the guide of another branch (the docs workflow builds
  // every version with this generator). Its navigation is used when it has
  // one; otherwise this one, without missing pages and with extra pages at
  // the end, so an older branch still builds.
  final source = option('guide');
  final siteGuide = source == null ? guide : Directory(source);
  var nav = localNav;
  if (source != null) {
    final own = File('$source/navigation.yaml');
    nav = reconcileNavigation(
      siteGuide,
      own.existsSync() ? readNavigation(own) : localNav,
    );
  }

  if (check) {
    if (changed.isNotEmpty) {
      stderr.writeln(
        'Stale documentation (run `dart run tool/docs/generate.dart`):\n'
        '  ${changed.join('\n  ')}',
      );
      exitCode = 1;
    } else {
      stdout.writeln('docs/guide is up to date.');
    }
    return;
  }
  final (defaultVersion, versions) = readVersions(File('docs/versions.yaml'));
  final version = option('version') ?? defaultVersion;
  final out = Directory(option('out') ?? 'build/site');
  final pages = buildSite(
    guide: siteGuide,
    out: out,
    version: version,
    defaultVersion: defaultVersion,
    versions: versions,
    nav: nav,
    releaseVersion: _releaseVersion(),
    clean: !args.contains('--keep'),
  );
  stdout.writeln(
    'Updated ${changed.length} guide file(s); built $pages pages of '
    '$version in ${out.path}.',
  );
}

String _releaseVersion() =>
    RegExp(r"daravelVersion = '([^']+)'")
        .firstMatch(
          File('packages/daravel/lib/src/foundation/version.dart')
              .readAsStringSync(),
        )
        ?.group(1) ??
    'dev';

Iterable<File> _markdownFiles(Directory dir) =>
    dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.md'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// `docs/guide/parity.md` from `parity.yaml`.
String renderParity(File source) {
  final parity = loadYaml(source.readAsStringSync()) as YamlMap;
  String cell(Object? value) =>
      '`${'$value'.replaceAll('|', r'\|').replaceAll('`', "'")}`';
  final out = StringBuffer()
    ..writeln('<!-- GENERATED from parity.yaml by tool/docs/generate.dart. -->')
    ..writeln()
    ..writeln('# Laravel ⇄ Daravel parity')
    ..writeln()
    ..writeln(
      'Laravel ${parity['laravel']} on the left, Daravel ${parity['daravel']} '
      'on the right. Every Daravel symbol below is checked against the source '
      'by `packages/daravel/test/parity_test.dart`, so this table cannot drift '
      'from the code. **async** marks calls you `await`.',
    );
  for (final section in (parity['sections'] as YamlList).cast<YamlMap>()) {
    out
      ..writeln()
      ..writeln('## ${section['name']}')
      ..writeln()
      ..writeln('| Laravel | Daravel | Notes |')
      ..writeln('| :-- | :-- | :-- |');
    for (final entry in (section['symbols'] as YamlList).cast<YamlMap>()) {
      final notes = [
        if (entry['async'] == true) '**async**',
        if (entry['throws'] != null) 'throws `${entry['throws']}`',
        if (entry['note'] != null) '${entry['note']}',
      ].join('; ');
      out.writeln(
        '| ${cell(entry['php'])} | ${cell(entry['dart'])} | $notes |',
      );
    }
  }
  final aliases = parity['middlewareAliases'] as YamlMap;
  out
    ..writeln()
    ..writeln('## Middleware aliases')
    ..writeln()
    ..writeln('| Laravel | Daravel |')
    ..writeln('| :-- | :-- |');
  aliases.forEach((php, dart) => out.writeln('| `$php` | `$dart` |'));
  out
    ..writeln()
    ..writeln('## Not available yet')
    ..writeln()
    ..writeln('| Laravel | Plan |')
    ..writeln('| :-- | :-- |');
  for (final entry in (parity['missing'] as YamlList).cast<YamlMap>()) {
    out.writeln('| ${entry['php']} | ${entry['plan']} |');
  }
  return out.toString();
}

final RegExp _include = RegExp(
  r'<!-- include: ([^#\s]+)#([\w-]+) -->\n.*?<!-- /include -->',
  dotAll: true,
);

/// Replaces include blocks with the referenced regions.
String expandIncludes(String markdown) => markdown.replaceAllMapped(_include, (
  match,
) {
  final path = match.group(1)!;
  final region = match.group(2)!;
  final code = extractRegion(File(path).readAsStringSync(), region, path);
  return '<!-- include: $path#$region -->\n```dart\n$code\n```\n<!-- /include -->';
});

/// Lines between `// #region name` and `// #endregion name`, dedented.
String extractRegion(String source, String region, String path) {
  final lines = source.split('\n');
  final start = lines.indexWhere((l) => l.trim() == '// #region $region');
  final end = lines.indexWhere((l) => l.trim() == '// #endregion $region');
  if (start == -1 || end <= start) {
    throw StateError('Region [$region] not found in $path.');
  }
  final body = lines
      .sublist(start + 1, end)
      .where((l) => !l.trim().startsWith('// #'))
      .toList();
  final indent = body
      .where((l) => l.trim().isNotEmpty)
      .map((l) => l.length - l.trimLeft().length)
      .fold<int>(1 << 30, (a, b) => a < b ? a : b);
  return body
      .map((l) => l.length >= indent ? l.substring(indent) : l.trimLeft())
      .join('\n')
      .trimRight();
}
