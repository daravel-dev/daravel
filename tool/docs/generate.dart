import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:yaml/yaml.dart';

/// Documentation site generator (BLUEPRINT_V2 §14.4, §11.3):
///
/// ```bash
/// dart run tool/docs/generate.dart          # refresh docs/guide, build build/site
/// dart run tool/docs/generate.dart --check  # CI: fail when docs/guide is stale
/// ```
///
/// 1. Renders `docs/guide/parity.md` from `parity.yaml` (side-by-side
///    Laravel ⇄ Daravel tables).
/// 2. Replaces every `<!-- include: path#region -->` … `<!-- /include -->`
///    block with that region of a compiled test file, so guide snippets are
///    the code the test suite runs.
/// 3. Builds a static HTML site from `docs/guide` into `build/site`.
void main(List<String> args) {
  final check = args.contains('--check');
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
  final pages = buildSite(guide, Directory('build/site'));
  stdout.writeln(
    'Updated ${changed.length} guide file(s); built $pages pages in build/site.',
  );
}

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

/// Converts every guide page to HTML with a shared layout and navigation.
int buildSite(Directory guide, Directory out) {
  if (out.existsSync()) {
    out.deleteSync(recursive: true);
  }
  final files = _markdownFiles(guide).toList();
  final nav = <(String, String)>[];
  for (final file in files) {
    final relative = file.path
        .substring(guide.path.length + 1)
        .replaceAll(r'\', '/');
    final title = _title(file.readAsStringSync()) ?? relative;
    nav.add((relative.replaceAll(RegExp(r'\.md$'), '.html'), title));
  }
  for (final file in files) {
    final relative = file.path
        .substring(guide.path.length + 1)
        .replaceAll(r'\', '/');
    final depth = '../' * (relative.split('/').length - 1);
    final html = md.markdownToHtml(
      file.readAsStringSync().replaceAllMapped(
        RegExp(r'\]\(([^)#]+)\.md(#[^)]*)?\)'),
        (m) => '](${m[1]}.html${m[2] ?? ''})',
      ),
      extensionSet: md.ExtensionSet.gitHubWeb,
    );
    final links = nav
        .where((entry) => !entry.$1.contains('/'))
        .map(
          (entry) =>
              '<a href="$depth${entry.$1}"'
              '${entry.$1 == relative.replaceAll('.md', '.html') ? ' class="active"' : ''}'
              '>${_escape(entry.$2)}</a>',
        )
        .join('\n');
    final target = File(
      '${out.path}/${relative.replaceAll(RegExp(r'\.md$'), '.html')}',
    )..parent.createSync(recursive: true);
    target.writeAsStringSync(
      _layout(_title(file.readAsStringSync()) ?? 'Daravel', links, html, depth),
    );
  }
  return files.length;
}

String? _title(String markdown) =>
    RegExp(r'^# (.+)$', multiLine: true).firstMatch(markdown)?.group(1);

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _layout(String title, String nav, String body, String depth) =>
    '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_escape(title)} · Daravel</title>
<style>
:root { --fg:#1d1d24; --muted:#5d5d6b; --bg:#ffffff; --panel:#f5f5f8; --accent:#c2410c; --border:#e3e3ea; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#ececf1; --muted:#a0a0ad; --bg:#14141a; --panel:#1d1d25; --accent:#fb923c; --border:#2c2c36; }
}
* { box-sizing: border-box; }
body { margin:0; font:16px/1.6 system-ui, sans-serif; color:var(--fg); background:var(--bg); }
.layout { display:flex; min-height:100vh; }
nav { width:250px; flex:none; padding:24px 16px; background:var(--panel); border-right:1px solid var(--border); }
nav .brand { font-weight:700; font-size:20px; margin-bottom:16px; display:block; color:var(--fg); text-decoration:none; }
nav a { display:block; padding:4px 8px; color:var(--muted); text-decoration:none; border-radius:6px; }
nav a.active, nav a:hover { color:var(--fg); background:var(--bg); }
main { flex:1; min-width:0; padding:32px 40px; max-width:960px; }
a { color:var(--accent); }
pre { background:var(--panel); border:1px solid var(--border); border-radius:8px; padding:14px 16px; overflow-x:auto; font-size:14px; }
code { font:14px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
table { border-collapse:collapse; width:100%; display:block; overflow-x:auto; }
th, td { border:1px solid var(--border); padding:6px 10px; text-align:left; vertical-align:top; }
th { background:var(--panel); }
@media (max-width: 760px) { .layout { display:block; } nav { width:auto; } main { padding:20px 16px; } }
</style>
</head>
<body>
<div class="layout">
<nav><a class="brand" href="${depth}index.html">Daravel</a>
$nav
</nav>
<main>
$body
</main>
</div>
</body>
</html>
''';
