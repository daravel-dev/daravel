import 'dart:convert';
import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:yaml/yaml.dart';

import 'landing.dart';

/// One entry of `docs/versions.yaml`.
final class DocsVersion {
  const DocsVersion(this.id, this.label, {this.development = false});

  final String id;
  final String label;
  final bool development;
}

/// `docs/versions.yaml`: the default version id and every version.
(String, List<DocsVersion>) readVersions(File file) {
  final yaml = loadYaml(file.readAsStringSync()) as YamlMap;
  return (
    '${yaml['default']}',
    [
      for (final entry in yaml['versions'] as YamlList)
        DocsVersion(
          '${(entry as YamlMap)['id']}',
          '${entry['label']}',
          development: entry['development'] == true,
        ),
    ],
  );
}

/// A sidebar category from `docs/guide/navigation.yaml`.
final class NavCategory {
  const NavCategory(this.title, this.pages);

  final String title;
  final List<String> pages;
}

List<NavCategory> readNavigation(File file) => [
  for (final entry in loadYaml(file.readAsStringSync()) as YamlList)
    NavCategory('${(entry as YamlMap)['title']}', [
      for (final page in entry['pages'] as YamlList) '$page',
    ]),
];

/// Problems with the navigation: pages listed but missing, and guide pages
/// that are not listed.
List<String> checkNavigation(Directory guide, List<NavCategory> nav) {
  final listed = {for (final c in nav) ...c.pages};
  final existing = {
    for (final file in guide.listSync().whereType<File>())
      if (file.path.endsWith('.md'))
        file.uri.pathSegments.last.replaceAll('.md', ''),
  };
  return [
    for (final page in listed.difference(existing))
      'navigation.yaml lists "$page" but docs/guide/$page.md does not exist',
    for (final page in existing.difference(listed))
      'docs/guide/$page.md is not listed in docs/guide/navigation.yaml',
  ];
}

const Map<String, String> _categoryId = {
  'Prologue': 'Prolog',
  'Getting started': 'Memulai',
  'Architecture': 'Arsitektur',
  'The basics': 'Dasar',
  'Database': 'Database',
  'Security': 'Keamanan',
  'Digging deeper': 'Lebih dalam',
  'Testing and performance': 'Pengujian dan performa',
  'More': 'Lainnya',
};

/// User interface text in English and Indonesian.
const Map<String, Map<String, String>> ui = {
  'en': {
    'search': 'Search the docs',
    'searchPlaceholder': 'Search the documentation',
    'onThisPage': 'On this page',
    'previous': 'Previous',
    'next': 'Next',
    'docs': 'Documentation',
    'parity': 'Laravel parity',
    'migrating': 'Migrating from Laravel',
    'performance': 'Performance',
    'menu': 'Menu',
    'skip': 'Skip to content',
    'devBanner':
        'You are reading the documentation of the development branch '
        '(main). For the current release, switch to',
    'edit': 'Edit this page',
  },
  'id': {
    'search': 'Cari dokumentasi',
    'searchPlaceholder': 'Cari di dokumentasi',
    'onThisPage': 'Di halaman ini',
    'previous': 'Sebelumnya',
    'next': 'Berikutnya',
    'docs': 'Dokumentasi',
    'parity': 'Paritas Laravel',
    'migrating': 'Migrasi dari Laravel',
    'performance': 'Performa',
    'menu': 'Menu',
    'skip': 'Lompat ke isi',
    'devBanner':
        'Anda membaca dokumentasi branch pengembangan (main). Untuk rilis '
        'saat ini, pindah ke',
    'untranslated':
        'Halaman ini belum diterjemahkan ke Bahasa Indonesia; isinya '
        'ditampilkan dalam bahasa Inggris.',
    'edit': 'Sunting halaman ini',
  },
};

/// A rendered guide page.
final class _Page {
  _Page({
    required this.slug,
    required this.lang,
    required this.title,
    required this.html,
    required this.headings,
    required this.text,
    required this.translated,
    required this.source,
  });

  final String slug;
  final String lang;
  final String title;
  final String html;
  final List<(int, String, String)> headings; // level, id, text
  final String text;
  final bool translated;
  final String source;
}

/// Builds the whole site (landing pages, shared assets, redirects) and the
/// documentation of [version] into [out].
int buildSite({
  required Directory guide,
  required Directory out,
  required String version,
  required String defaultVersion,
  required List<DocsVersion> versions,
  required List<NavCategory> nav,
  required String releaseVersion,
  bool clean = true,
}) {
  if (clean && out.existsSync()) {
    out.deleteSync(recursive: true);
  }
  out.createSync(recursive: true);
  _copyAssets(out);

  final current = versions.firstWhere(
    (v) => v.id == version,
    orElse: () => DocsVersion(version, version),
  );
  final docsDir = Directory('${out.path}/docs/$version');
  if (docsDir.existsSync()) {
    docsDir.deleteSync(recursive: true);
  }

  final pages = <String, Map<String, _Page>>{'en': {}, 'id': {}};
  for (final category in nav) {
    for (final slug in category.pages) {
      final english = File('${guide.path}/$slug.md');
      pages['en']![slug] = _render(english, slug, 'en', translated: true);
      final indonesian = File('${guide.path}/id/$slug.md');
      pages['id']![slug] = indonesian.existsSync()
          ? _render(indonesian, slug, 'id', translated: true)
          : _render(english, slug, 'id', translated: false);
    }
  }
  final order = [for (final c in nav) ...c.pages];
  var count = 0;
  for (final lang in ['en', 'id']) {
    for (final slug in order) {
      final page = pages[lang]![slug]!;
      final index = order.indexOf(slug);
      final file = File(
        '${docsDir.path}/${lang == 'en' ? '' : 'id/'}$slug.html',
      )..parent.createSync(recursive: true);
      file.writeAsStringSync(
        _docPage(
          page: page,
          nav: nav,
          pages: pages[lang]!,
          previous: index > 0 ? pages[lang]![order[index - 1]] : null,
          next: index < order.length - 1
              ? pages[lang]![order[index + 1]]
              : null,
          version: current,
          defaultVersion: defaultVersion,
          versions: versions,
          releaseVersion: releaseVersion,
        ),
      );
      count++;
    }
  }

  File('${docsDir.path}/search-index.json').writeAsStringSync(
    jsonEncode({
      'version': version,
      'pages': [
        for (final lang in ['en', 'id'])
          for (final category in nav)
            for (final slug in category.pages)
              {
                'title': pages[lang]![slug]!.title,
                'url': '${lang == 'en' ? '' : 'id/'}$slug.html',
                'lang': lang,
                'category': lang == 'en'
                    ? category.title
                    : _categoryId[category.title] ?? category.title,
                'headings': [
                  for (final (_, id, text) in pages[lang]![slug]!.headings)
                    {'id': id, 'text': text},
                ],
                'text': pages[lang]![slug]!.text,
              },
      ],
    }),
  );

  // Shared files (identical for every version build).
  final docsRoot = Directory('${out.path}/docs')..createSync(recursive: true);
  File('${docsRoot.path}/versions.json').writeAsStringSync(
    jsonEncode({
      'default': defaultVersion,
      'versions': [
        for (final v in versions)
          {'id': v.id, 'label': v.label, 'development': v.development},
      ],
    }),
  );
  File('${docsRoot.path}/index.html')
      .writeAsStringSync(_redirect('$defaultVersion/index.html'));
  if (version == defaultVersion) {
    // Links to the old flat site keep working.
    for (final slug in order) {
      File('${out.path}/$slug.html')
          .writeAsStringSync(_redirect('docs/$defaultVersion/$slug.html'));
    }
  }
  // Every build writes the landing pages (the last build wins); links go
  // to a version that has the page.
  for (final lang in ['en', 'id']) {
    final file = File('${out.path}/${lang == 'en' ? '' : 'id/'}index.html')
      ..parent.createSync(recursive: true);
    file.writeAsStringSync(
      landingPage(
        lang: lang,
        docs:
            '${lang == 'en' ? '' : '../'}docs/$defaultVersion/'
            '${lang == 'en' ? '' : 'id/'}',
        prefix: lang == 'en' ? '' : '../',
        releaseVersion: releaseVersion,
        link: (page) {
          // The release version when it has the page, else a version that
          // does (pages added on main before the next release).
          final dir = lang == 'en' ? '' : 'id/';
          final up = lang == 'en' ? '' : '../';
          for (final v in [
            defaultVersion,
            for (final other in versions)
              if (other.id != defaultVersion) other.id,
          ]) {
            if (File('${out.path}/docs/$v/$dir$page').existsSync()) {
              return '${up}docs/$v/$dir$page';
            }
          }
          return '${up}docs/$defaultVersion/${dir}index.html';
        },
      ),
    );
  }
  File('${out.path}/CNAME').writeAsStringSync('daravel.dev\n');
  return count;
}

void _copyAssets(Directory out) {
  final assets = Directory('${out.path}/assets/brand')
    ..createSync(recursive: true);
  for (final name in ['site.css', 'site.js']) {
    File('tool/docs/site/$name').copySync('${out.path}/assets/$name');
  }
  for (final file in Directory('docs/brand/svg').listSync().whereType<File>()) {
    file.copySync('${assets.path}/${file.uri.pathSegments.last}');
  }
  for (final name in [
    'daravel-icon-180.png',
    'daravel-icon-192.png',
    'daravel-social-1280x640.png',
  ]) {
    File('docs/brand/png/$name').copySync('${assets.path}/$name');
  }
  File('docs/brand/favicon.ico').copySync('${out.path}/favicon.ico');
}

_Page _render(File file, String slug, String lang, {required bool translated}) {
  final source = file.readAsStringSync();
  final title =
      RegExp(r'^# (.+)$', multiLine: true).firstMatch(source)?.group(1) ?? slug;
  var html = md.markdownToHtml(
    source.replaceAllMapped(
      RegExp(r'\]\(([^)#:]+)\.md(#[^)]*)?\)'),
      (m) => '](${m[1]}.html${m[2] ?? ''})',
    ),
    extensionSet: md.ExtensionSet.gitHubWeb,
  );
  final headings = <(int, String, String)>[];
  html = html.replaceAllMapped(RegExp(r'<h([23]) id="([^"]+)">(.*?)</h\1>'), (
    m,
  ) {
    final text = _stripTags(m[3]!);
    headings.add((int.parse(m[1]!), m[2]!, text));
    return '<h${m[1]} id="${m[2]}">${m[3]}'
        '<a class="anchor" href="#${m[2]}" aria-label="Link to this section">#</a>'
        '</h${m[1]}>';
  });
  final text = _stripTags(html).replaceAll(RegExp(r'\s+'), ' ').trim();
  return _Page(
    slug: slug,
    lang: lang,
    title: _unescape(_stripTags(md.markdownToHtml(title))),
    html: html,
    headings: headings,
    text: text.length > 400 ? text.substring(0, 400) : text,
    translated: translated,
    source: file.path.replaceAll(r'\', '/'),
  );
}

String _stripTags(String html) =>
    _unescape(html.replaceAll(RegExp('<[^>]+>'), ''));

String _unescape(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

String escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _redirect(String target) =>
    '''
<!doctype html>
<meta charset="utf-8">
<title>Daravel</title>
<meta http-equiv="refresh" content="0; url=$target">
<link rel="canonical" href="$target">
<a href="$target">$target</a>
''';

/// The `<head>` and header shared by every page. [prefix] leads from the
/// page to the site root.
String pageHead({
  required String title,
  required String prefix,
  required String lang,
  String description =
      'The Laravel developer experience, compiled to a single native binary.',
}) =>
    '''
<!doctype html>
<html lang="$lang">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<meta name="description" content="${escapeHtml(description)}">
<meta property="og:title" content="${escapeHtml(title)}">
<meta property="og:description" content="${escapeHtml(description)}">
<meta property="og:image" content="https://daravel.dev/assets/brand/daravel-social-1280x640.png">
<link rel="icon" href="${prefix}favicon.ico">
<link rel="apple-touch-icon" href="${prefix}assets/brand/daravel-icon-180.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Schibsted+Grotesk:wght@400;500;600;700;800&display=swap">
<link rel="stylesheet" href="${prefix}assets/site.css">
<script src="${prefix}assets/site.js"></script>
</head>
''';

/// The top bar. [docs] leads to the docs of the current language.
String topBar({
  required String prefix,
  required String docs,
  required String lang,
  required String releaseVersion,
  required String enHref,
  required String idHref,
  bool menu = false,
}) {
  final t = ui[lang]!;
  return '''
<a class="skip" href="#content">${t['skip']}</a>
<header class="topbar">
${menu ? '<button class="tool-button menu-toggle" type="button" data-menu-toggle aria-expanded="false">${t['menu']}</button>' : ''}
<a class="brand" href="$prefix${lang == 'en' ? '' : 'id/'}index.html"><img src="${prefix}assets/brand/daravel-icon.svg" alt="" width="30" height="30">Daravel<span class="ver">v$releaseVersion</span></a>
<nav class="topnav" aria-label="Main">
<a href="${docs}getting-started.html">${t['docs']}</a>
<a href="${docs}parity.html">${t['parity']}</a>
<a href="${docs}migrating-from-laravel.html">${t['migrating']}</a>
<a href="${docs}performance.html">${t['performance']}</a>
</nav>
<div class="tools">
<button class="tool-button search-trigger" type="button" data-search-open aria-label="${t['search']}"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><span class="label">${t['search']}</span><kbd>Ctrl K</kbd></button>
<span class="lang"><a href="$enHref"${lang == 'en' ? ' aria-current="true"' : ''} hreflang="en">EN</a><a href="$idHref"${lang == 'id' ? ' aria-current="true"' : ''} hreflang="id">ID</a></span>
<button class="tool-button" type="button" data-theme-toggle>System</button>
<a class="tool-button github" href="https://github.com/daravel-dev/daravel">GitHub</a>
</div>
</header>
''';
}

/// The search dialog; [index] and [base] are relative to the page.
String searchDialog({
  required String index,
  required String base,
  required String lang,
}) =>
    '''
<dialog class="search-dialog" data-index="$index" data-base="$base" data-lang="$lang" aria-label="${ui[lang]!['search']}">
<input type="search" placeholder="${ui[lang]!['searchPlaceholder']}" aria-label="${ui[lang]!['searchPlaceholder']}" autocomplete="off">
<ul class="search-results" role="listbox"></ul>
</dialog>
''';

String _docPage({
  required _Page page,
  required List<NavCategory> nav,
  required Map<String, _Page> pages,
  required _Page? previous,
  required _Page? next,
  required DocsVersion version,
  required String defaultVersion,
  required List<DocsVersion> versions,
  required String releaseVersion,
}) {
  final lang = page.lang;
  final t = ui[lang]!;
  final inId = lang == 'id';
  // From docs/<version>/[id/] back to the site root and to the version.
  final prefix = inId ? '../../../' : '../../';
  final versionBase = inId ? '../' : '';
  final sidebar = StringBuffer()
    ..writeln(
      '<select class="version-select" aria-label="Version" data-version-select '
      'data-docs-root="$prefix'
      'docs/" data-page="${inId ? 'id/' : ''}${page.slug}.html">',
    );
  for (final v in versions) {
    sidebar.writeln(
      '<option value="${v.id}"${v.id == version.id ? ' selected' : ''}>'
      '${escapeHtml(v.label)}</option>',
    );
  }
  sidebar.writeln('</select>');
  for (final category in nav) {
    final open = category.pages.contains(page.slug);
    final title = inId
        ? _categoryId[category.title] ?? category.title
        : category.title;
    sidebar
      ..writeln('<details${open ? ' open' : ''}>')
      ..writeln('<summary>${escapeHtml(title)}</summary>')
      ..writeln('<ul>');
    for (final slug in category.pages) {
      final current = slug == page.slug ? ' aria-current="page"' : '';
      sidebar.writeln(
        '<li><a href="$slug.html"$current>'
        '${escapeHtml(pages[slug]!.title)}</a></li>',
      );
    }
    sidebar
      ..writeln('</ul>')
      ..writeln('</details>');
  }

  final toc = page.headings.isEmpty
      ? ''
      : '<aside class="toc" aria-label="${t['onThisPage']}"><p>${t['onThisPage']}</p><ul>'
            '${page.headings.map((h) => '<li${h.$1 == 3 ? ' class="sub"' : ''}><a href="#${h.$2}">${escapeHtml(h.$3)}</a></li>').join()}'
            '</ul></aside>';

  final banners = StringBuffer();
  if (version.development) {
    banners.writeln(
      '<p class="banner">${t['devBanner']} '
      '<a href="$prefix'
      'docs/$defaultVersion/${inId ? 'id/' : ''}index.html">'
      '$defaultVersion</a>.</p>',
    );
  }
  if (!page.translated) {
    banners.writeln('<p class="banner" lang="id">${t['untranslated']}</p>');
  }

  final pager = StringBuffer('<nav class="pager" aria-label="Pages">');
  if (previous != null) {
    pager.write(
      '<a class="prev" href="${previous.slug}.html"><span>${t['previous']}</span>'
      '${escapeHtml(previous.title)}</a>',
    );
  }
  if (next != null) {
    pager.write(
      '<a class="next" href="${next.slug}.html"><span>${t['next']}</span>'
      '${escapeHtml(next.title)}</a>',
    );
  }
  pager.write('</nav>');

  return '''
${pageHead(title: '${page.title} | Daravel ${version.label}', prefix: prefix, lang: lang)}
<body>
${topBar(prefix: prefix, docs: '', lang: lang, releaseVersion: releaseVersion, enHref: '$versionBase${page.slug}.html', idHref: '${inId ? '' : 'id/'}${page.slug}.html', menu: true)}
<div class="docs">
<nav class="sidebar" aria-label="${t['docs']}">
$sidebar
</nav>
<main class="article" id="content">
$banners<article class="prose"${!page.translated ? ' lang="en"' : ''}>
${page.html}
</article>
$pager
</main>
$toc
</div>
${searchDialog(index: '${versionBase}search-index.json', base: versionBase, lang: lang)}
</body>
</html>
''';
}

/// [nav] without pages missing from [guide], plus the guide's unlisted
/// pages in a last category, for building another branch's guide.
List<NavCategory> reconcileNavigation(Directory guide, List<NavCategory> nav) {
  bool exists(String slug) => File('${guide.path}/$slug.md').existsSync();
  final listed = {for (final c in nav) ...c.pages};
  final extra = [
    for (final file in guide.listSync().whereType<File>())
      if (file.path.endsWith('.md'))
        file.uri.pathSegments.last.replaceAll('.md', ''),
  ].where((slug) => !listed.contains(slug)).toList()..sort();
  return [
    for (final category in nav)
      if (category.pages.any(exists))
        NavCategory(category.title, category.pages.where(exists).toList()),
    if (extra.isNotEmpty) NavCategory('More', extra),
  ];
}
